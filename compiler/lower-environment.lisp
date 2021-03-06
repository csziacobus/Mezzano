;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Lower non-local lexical variable accesses so they refer directly
;;;; to environment objects.
;;;; This is done in two passes.
;;;; Pass 1 discovers escaping variables & assigns them slots
;;;; in their environment vector. Determines the extent of every lambda.
;;;; Pass 2 links each environment vector together and actually
;;;; rewrites the code.
;;;; Vectors are created at LAMBDA and TAGBODY nodes.

(in-package :sys.c)

(defvar *environment-chain*)
(defvar *environment-layout*)
(defvar *environment-layout-dx*)
(defvar *active-environment-vector*)
(defvar *allow-dx-environment*)
(defvar *environment-allocation-mode* nil)

(defun lower-environment (lambda)
  (let ((*environment-layout* (make-hash-table))
        (*environment-layout-dx* (make-hash-table)))
    (compute-environment-layout lambda)
    (let ((*environment* '()))
      (lower-env-form lambda))))

(defun quoted-form-p (form)
  (and (listp form)
       (cdr form)
       (null (cddr form))
       (eql (first form) 'quote)))

(defun compute-environment-layout (form)
  (etypecase form
    (cons (case (first form)
	    ((block)
             (compute-block-environment-layout form))
	    ((go) nil)
	    ((if)
             (mapc #'compute-environment-layout (rest form)))
	    ((let)
             (compute-let-environment-layout form))
	    ((load-time-value) (error "TODO LOAD-TIME-VALUE"))
	    ((multiple-value-bind)
             (compute-mvb-environment-layout form))
	    ((multiple-value-call)
             (mapc #'compute-environment-layout (rest form)))
	    ((multiple-value-prog1)
             (mapc #'compute-environment-layout (rest form)))
	    ((progn)
             (mapc #'compute-environment-layout (rest form)))
	    ((function quote) nil)
	    ((return-from)
             (compute-environment-layout (rest form)))
	    ((setq)
             (compute-environment-layout (third form)))
	    ((tagbody)
             (compute-tagbody-environment-layout form))
	    ((the)
             (compute-environment-layout (third form)))
	    ((unwind-protect)
             (compute-environment-layout (second form))
             (cond ((lambda-information-p (third form))
                    (unless (getf (lambda-information-plist (third form)) 'extent)
                        (setf (getf (lambda-information-plist (third form)) 'extent) :dynamic))
                    (compute-lambda-environment-layout (third form)))
                   (t (compute-environment-layout (third form)))))
	    (t (cond ((and (eql (first form) 'funcall)
                           (lambda-information-p (second form)))
                      (unless (getf (lambda-information-plist (second form)) 'extent)
                        (setf (getf (lambda-information-plist (second form)) 'extent) :dynamic))
                      (compute-lambda-environment-layout (second form))
                      (mapc #'compute-environment-layout (cddr form)))
                     (t (mapc #'compute-environment-layout (rest form)))))))
    (lexical-variable nil)
    (lambda-information
     (setf (getf (lambda-information-plist form) 'dynamic-extent) :indefinite)
     (compute-lambda-environment-layout form))))

(defun maybe-add-environment-variable (variable)
  (when (and (not (symbolp variable))
             (not (localp variable)))
    (push variable (gethash *active-environment-vector* *environment-layout*))))

(defun finalize-environment-layout (env)
  ;; Inner environments must be DX, and every variable in this environment
  ;; must only be accessed by DX lambdas.
  (when (and *allow-dx-environment*
             (every (lambda (var)
                      (every (lambda (l)
                               (or (eql (lexical-variable-definition-point var) l)
                                   (eql (getf (lambda-information-plist l) 'extent) :dynamic)
                                   (getf (lambda-information-plist l) 'declared-dynamic-extent)))
                             (lexical-variable-used-in var)))
                    (gethash env *environment-layout*)))
    (setf (gethash env *environment-layout-dx*) t)
    t))

(defun compute-lambda-environment-layout (lambda)
  (let ((env-is-dx nil))
    (let ((*active-environment-vector* lambda)
          (*allow-dx-environment* t))
      (assert (null (lambda-information-environment-arg lambda)))
      ;; Special variables are not supported here, nor are keywords or non-trivial &OPTIONAL init-forms.
      (assert (every (lambda (arg)
                       (lexical-variable-p arg))
                     (lambda-information-required-args lambda)))
      (assert (every (lambda (arg)
                       (and (lexical-variable-p (first arg))
                            (quoted-form-p (second arg))
                            (or (null (third arg))
                                (lexical-variable-p (first arg)))))
                     (lambda-information-optional-args lambda)))
      (assert (or (null (lambda-information-rest-arg lambda))
                  (lexical-variable-p (lambda-information-rest-arg lambda))))
      (assert (not (lambda-information-enable-keys lambda)))
      (dolist (arg (lambda-information-required-args lambda))
        (maybe-add-environment-variable arg))
      (dolist (arg (lambda-information-optional-args lambda))
        (maybe-add-environment-variable (first arg))
        (when (third arg)
          (maybe-add-environment-variable (third arg))))
      (when (lambda-information-rest-arg lambda)
        (maybe-add-environment-variable (lambda-information-rest-arg lambda)))
      (compute-environment-layout `(progn ,@(lambda-information-body lambda)))
      (setf env-is-dx (finalize-environment-layout lambda)))
    (unless env-is-dx
      (setf *allow-dx-environment* nil))))

(defun compute-tagbody-environment-layout (form)
  "TAGBODY defines a single variable in the enclosing environment and each group
of statements opens a new contour."
  (maybe-add-environment-variable (second form))
  (let ((env-is-dx t))
    (let ((*active-environment-vector* (second form))
          (*allow-dx-environment* t))
      (dolist (stmt (cddr form))
        (cond ((go-tag-p stmt)
               (unless (finalize-environment-layout *active-environment-vector*)
                 (setf env-is-dx nil))
               (setf *active-environment-vector* stmt
                     *allow-dx-environment* t))
              (t (compute-environment-layout stmt))))
      (unless (finalize-environment-layout *active-environment-vector*)
        (setf env-is-dx nil)))
    (unless env-is-dx
      (setf *allow-dx-environment* nil))))

(defun compute-block-environment-layout (form)
  "BLOCK defines one variable."
  (maybe-add-environment-variable (second form))
  (mapc #'compute-environment-layout (cddr form)))

(defun compute-let-environment-layout (form)
  (dolist (binding (second form))
    (maybe-add-environment-variable (first binding))
    (compute-environment-layout (second binding)))
  (mapc #'compute-environment-layout (cddr form)))

(defun compute-mvb-environment-layout (form)
  (dolist (binding (second form))
    (maybe-add-environment-variable binding))
  (mapc #'compute-environment-layout (cddr form)))

(defun lower-env-form (form)
  (etypecase form
    (cons (case (first form)
	    ((block) (le-block form))
            ((function) form)
	    ((go) (le-go form))
	    ((if) (le-form*-cdr form))
	    ((let) (le-let form))
	    ((load-time-value) (le-load-time-value form))
	    ((multiple-value-bind) (le-multiple-value-bind form))
	    ((multiple-value-call) (le-form*-cdr form))
	    ((multiple-value-prog1) (le-form*-cdr form))
	    ((progn) (le-form*-cdr form))
	    ((quote) form)
	    ((return-from) (le-return-from form))
	    ((setq) (le-setq form))
	    ((tagbody) (le-tagbody form))
	    ((the) (le-the form))
	    ((unwind-protect) (le-form*-cdr form))
	    (t (le-form*-cdr form))))
    (lexical-variable (le-variable form))
    (lambda-information
     (cond ((not *environment-chain*)
            (le-lambda form))
           ((getf (lambda-information-plist form) 'declared-dynamic-extent)
            `(sys.c::make-dx-closure
              ,(le-lambda form)
              ,(second (first *environment-chain*))))
           (*environment-allocation-mode*
            `(sys.int::make-closure
              ,(le-lambda form)
              ,(second (first *environment-chain*))
              ',*environment-allocation-mode*))
           (t `(sys.int::make-closure
                ,(le-lambda form)
                ,(second (first *environment-chain*))))))))

(defvar *environment-chain* nil
  "The directly accessible environment vectors in this function.")

(defun compute-environment-layout-debug-info ()
  (when *environment*
    (list (second (first *environment-chain*))
          (mapcar (lambda (env)
                    (mapcar (lambda (x)
                              (if (or (tagbody-information-p x)
                                      (block-information-p x))
                                  nil
                                  (lexical-variable-name x)))
                            (gethash env *environment-layout*)))
                  *environment*))))

(defun generate-make-environment (lambda size)
  (cond ((gethash lambda *environment-layout-dx*)
         ;; DX allocation.
         `(sys.c::make-dx-simple-vector ',size))
        (*environment-allocation-mode*
         ;; Allocation in an explicit area.
         `(sys.int::make-simple-vector ',size ',*environment-allocation-mode*))
        ;; General allocation.
        (t `(sys.int::make-simple-vector ',size))))

(defun le-lambda (lambda)
  (let ((*environment-chain* '())
        (*environment* *environment*)
        (local-env (gethash lambda *environment-layout*))
        (*current-lambda* lambda)
        (*environment-allocation-mode* (let* ((declares (getf (lambda-information-plist lambda) :declares))
                                              (mode (assoc 'sys.c::closure-allocation declares)))
                                         (if (and mode (cdr mode))
                                             (second mode)
                                             *environment-allocation-mode*))))
    (when *environment*
      ;; The entry environment vector.
      (let ((env (make-lexical-variable :name (gensym "Environment")
                                        :definition-point lambda)))
        (setf (lambda-information-environment-arg lambda) env)
        (push (list (first *environment*) env) *environment-chain*)))
    (cond ((not (endp local-env))
           ;; Environment is present, rewrite body with a new vector.
           (let ((new-env (make-lexical-variable :name (gensym "Environment")
                                                 :definition-point lambda)))
             (push (list lambda new-env) *environment-chain*)
             (push lambda *environment*)
             (setf (lambda-information-environment-layout lambda) (compute-environment-layout-debug-info))
             (setf (lambda-information-body lambda)
                   `((let ((,new-env ,(generate-make-environment lambda (1+ (length local-env)))))
                       ,@(when (rest *environment-chain*)
                           (list (list '(setf sys.int::%svref)
                                       (second (second *environment-chain*))
                                       new-env
                                       ''0)))
                       ,@(mapcar (lambda (arg)
                                   (list '(setf sys.int::%svref)
                                         arg
                                         new-env
                                         `',(1+ (position arg local-env))))
                                 (remove-if #'localp (lambda-information-required-args lambda)))
                       ,@(mapcar (lambda (arg)
                                   (list '(setf sys.int::%svref)
                                         (first arg)
                                         new-env
                                         `',(1+ (position (first arg) local-env))))
                                 (remove-if #'localp (lambda-information-optional-args lambda)
                                            :key #'first))
                       ,@(mapcar (lambda (arg)
                                   (list '(setf sys.int::%svref)
                                         (third arg)
                                         new-env
                                         `',(1+ (position (third arg) local-env))))
                                 (remove-if #'(lambda (x) (or (null x) (localp x)))
                                            (lambda-information-optional-args lambda)
                                            :key #'third))
                       ,@(when (and (lambda-information-rest-arg lambda)
                                    (not (localp (lambda-information-rest-arg lambda))))
                               (list (list '(setf sys.int::%svref)
                                           (lambda-information-rest-arg lambda)
                                           new-env
                                           `',(1+ (position (lambda-information-rest-arg lambda) local-env)))))
                       ,@(mapcar #'lower-env-form (lambda-information-body lambda)))))))
          (t (setf (lambda-information-environment-layout lambda) (compute-environment-layout-debug-info))
             (setf (lambda-information-body lambda) (mapcar #'lower-env-form (lambda-information-body lambda)))))
    lambda))

(defun le-let (form)
  (setf (second form)
        (loop for (variable init-form) in (second form)
           collect (list variable (if (or (symbolp variable)
                                          (localp variable))
                                      (lower-env-form init-form)
                                      (list '(setf sys.int::%svref)
                                            (lower-env-form init-form)
                                            (second (first *environment-chain*))
                                            `',(1+ (position variable (gethash (first *environment*) *environment-layout*))))))))
  (setf (cddr form) (mapcar #'lower-env-form (cddr form)))
  form)

(defun get-env-vector (vector-id)
  (let ((chain (assoc vector-id *environment-chain*)))
    (when chain
      (return-from get-env-vector
        (second chain))))
  ;; Not in the chain, walk the rest of the environment.
  (do ((e *environment* (cdr e))
       (c *environment-chain* (cdr c)))
      ((null (cdr c))
       (let ((result (second (car c))))
         (dolist (env (cdr e)
                  (error "Can't find environment for ~S?" vector-id))
           (setf result `(sys.int::%svref ,result '0))
           (when (eql env vector-id)
             (return result)))))))

;;; Locate a variable in the environment.
(defun find-var (var env chain)
  (assert chain (var env chain) "No environment chain?")
  (assert env (var env chain) "No environment?")
  (cond ((member var (first env))
         (values (first chain) 0 (position var (first env))))
        ((rest chain)
         (find-var var (rest env) (rest chain)))
        (t ;; Walk the environment using the current chain as a root.
         (let ((depth 0))
           (dolist (e (rest env)
                    (error "~S not found in environment?" var))
             (incf depth)
             (when (member var e)
               (return (values (first chain) depth
                               (position var e)))))))))

(defun le-variable (form)
  (if (localp form)
      form
      (dolist (e *environment*
               (error "Can't find variable ~S in environment." form))
        (let* ((layout (gethash e *environment-layout*))
               (offset (position form layout)))
          (when offset
            (return `(sys.int::%svref ,(get-env-vector e) ',(1+ offset))))))))

(defun le-form*-cdr (form)
  (list* (first form)
         (mapcar #'lower-env-form (rest form))))

(defun le-block (form)
  (append (list (first form)
                (second form))
          (when (not (localp (second form)))
            (let ((env-var (second (first *environment-chain*)))
                  (env-offset (1+ (position (second form) (gethash (first *environment*) *environment-layout*)))))
              (setf (block-information-env-var (second form)) env-var
                    (block-information-env-offset (second form)) env-offset)
              (list (list '(setf sys.int::%svref)
                          (second form)
                          env-var
                          `',env-offset))))
          (mapcar #'lower-env-form (cddr form))))

(defun le-setq (form)
  (cond ((localp (second form))
         (setf (third form) (lower-env-form (third form)))
         form)
        (t (dolist (e *environment*
                    (error "Can't find variable ~S in environment." (second form)))
             (let* ((layout (gethash e *environment-layout*))
                    (offset (position (second form) layout)))
               (when offset
                 (return (list '(setf sys.int::%svref)
                               (lower-env-form (third form))
                               (get-env-vector e)
                               `',(1+ offset)))))))))

(defun le-multiple-value-bind (form)
  `(multiple-value-bind ,(second form)
       ,(lower-env-form (third form))
     ,@(mapcan (lambda (var)
                 (when (and (not (symbolp var))
                            (not (localp var)))
                   (list (list '(setf sys.int::%svref)
                               var
                               (second (first *environment-chain*))
                               `',(1+ (position var (gethash (first *environment*) *environment-layout*)))))))
               (second form))
     ,@(mapcar #'lower-env-form (cdddr form))))

(defun le-the (form)
  (setf (third form) (lower-env-form (third form)))
  form)

(defun le-go (form)
  (setf (third form) (lower-env-form (third form)))
  form)

(defun le-tagbody (form)
  (let* ((possible-env-vector-heads (list* (second form)
                                           (remove-if-not #'go-tag-p (cddr form))))
         (env-vector-heads (remove-if (lambda (x) (endp (gethash x *environment-layout*)))
                                      possible-env-vector-heads))
         (new-envs (loop for i in env-vector-heads
                      collect (list i
                                    (make-lexical-variable :name (gensym "Environment")
                                                           :definition-point *current-lambda*)
                                    (gethash i *environment-layout*)))))
    (labels ((frob-outer ()
             `(tagbody ,(second form)
                 ;; Save the tagbody info.
                 ,@(when (not (localp (second form)))
                     (let ((env-var (second (first *environment-chain*)))
                           (env-offset (1+ (position (second form) (gethash (first *environment*) *environment-layout*)))))
                       (setf (tagbody-information-env-var (second form)) env-var
                             (tagbody-information-env-offset (second form)) env-offset)
                       (list (list '(setf sys.int::%svref)
                                   (second form)
                                   env-var
                                   `',env-offset))))
                 ,@(let ((info (assoc (second form) new-envs)))
                     (when info
                       (if *environment*
                           (list `(setq ,(second info) ,(generate-make-environment (second form) (1+ (length (third info)))))
                                 (list '(setf sys.int::%svref)
                                       (second (first *environment-chain*))
                                       (second info)
                                       ''0))
                           (list `(setq ,(second info) ,(generate-make-environment (second form) (1+ (length (third info)))))))))
                 ,@(frob-inner (second form))))
             (frob-inner (current-env)
               (loop for stmt in (cddr form)
                  append (cond ((go-tag-p stmt)
                                (setf current-env stmt)
                                (let ((info (assoc current-env new-envs)))
                                  (append (list stmt)
                                          (when info
                                            (list `(setq ,(second info) ,(generate-make-environment current-env (1+ (length (third info)))))))
                                          (when (and info *environment*)
                                            (list (list '(setf sys.int::%svref)
                                                        (second (first *environment-chain*))
                                                        (second info)
                                                        ''0))))))
                                (t (let ((info (assoc current-env new-envs)))
                                     (if info
                                         (let ((*environment-chain* (list* (list current-env (second info))
                                                                           *environment-chain*))
                                               (*environment* (list* current-env *environment*)))
                                           (list (lower-env-form stmt)))
                                         (list (lower-env-form stmt)))))))))
      (if (endp new-envs)
          (frob-outer)
          `(let ,(loop for (stmt env layout) in new-envs
                    collect (list env ''nil))
             ,(frob-outer))))))

(defun le-return-from (form)
  (setf (third form) (lower-env-form (third form)))
  (setf (fourth form) (lower-env-form (fourth form)))
  form)
