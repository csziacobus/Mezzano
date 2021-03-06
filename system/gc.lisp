;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :sys.int)

(defvar *gc-debug-scavenge-stack* nil)
(defvar *gc-debug-freelist-rebuild* nil)

;;; GC Meters.
(defvar *objects-copied* 0)
(defvar *words-copied* 0)

(defvar *gc-in-progress* nil)

;; State of the dynamic pointer mark bit. This is part of the pointer, not part
;; of the object itself.
(defvar *dynamic-mark-bit* 0)
;; State of the object header mark bit, used for pinned objects.
(defvar *pinned-mark-bit* 0)

;; How many bytes the allocators can expand their areas by before a GC must occur.
;; This is shared between all areas.
(defvar *memory-expansion-remaining* 0)

;; What *MEMORY-EXPANSION-REMAINING* should be set to after a GC.
(defvar *memory-expansion* (* 64 1024 1024))

;; Current state of the stack mark bit. The value in this symbol is accessed
;; as a raw, untagged value by the DX allocation code. The value must be a
;; fixnum shifted n-fixnum-bits right to work correctly.
(declaim (special *current-stack-mark-bit*))

(defun room (&optional (verbosity :default))
  (let ((total-used 0)
        (total 0))
    (format t "General area: ~:D/~:D words used (~D%).~%"
            (truncate *general-area-bump* 8) (truncate *general-area-limit* 8)
            (truncate (* *general-area-bump* 100) *general-area-limit*))
    (incf total-used (truncate *general-area-bump* 8))
    (incf total (truncate *general-area-limit* 8))
    (format t "Cons area: ~:D/~:D words used (~D%).~%"
            (truncate *cons-area-bump* 8) (truncate *cons-area-limit* 8)
            (truncate (* *cons-area-bump* 100) *cons-area-limit*))
    (incf total-used (truncate *cons-area-bump* 8))
    (incf total (truncate *cons-area-limit* 8))
    (multiple-value-bind (allocated-words total-words largest-free-space)
        (pinned-area-info (* 2 1024 1024) *wired-area-bump*)
      (format t "Wired area: ~:D/~:D words allocated (~D%).~%"
              allocated-words total-words
              (truncate (* allocated-words 100) total-words))
      (format t "  Largest free area: ~:D words.~%" largest-free-space)
      (incf total-used allocated-words)
      (incf total total-words))
    (multiple-value-bind (allocated-words total-words largest-free-space)
        (pinned-area-info (* 2 1024 1024 1024) *pinned-area-bump*)
      (format t "Pinned area: ~:D/~:D words allocated (~D%).~%"
              allocated-words total-words
              (truncate (* allocated-words 100) total-words))
      (format t "  Largest free area: ~:D words.~%" largest-free-space)
      (incf total-used allocated-words)
      (incf total total-words))
    (format t "Total ~:D/~:D words used (~D%).~%"
            total-used total
            (truncate (* total-used 100) total))
    (multiple-value-bind (n-free-blocks total-blocks)
        (mezzano.supervisor:store-statistics)
      (format t "~:D/~:D store blocks used (~D%).~%"
              (- total-blocks n-free-blocks) total-blocks
              (truncate (* (- total-blocks n-free-blocks) 100) total-blocks)))
    (format t "~:D words to next GC.~%" (truncate *memory-expansion-remaining* 8)))
  (values))

(defun pinned-area-info (base limit)
  ;; Yup. Scanning a pinned area atomically requires the world to be stopped.
  (mezzano.supervisor:with-world-stopped
    (let ((allocated-words 0)
          (total-words 0)
          (offset 0)
          (largest-free-space 0))
      (loop
         (when (>= (+ base (* offset 8)) limit)
           (return))
         (let ((size (align-up (size-of-pinned-area-allocation (+ base (* offset 8))) 2))
               (type (ldb (byte +array-type-size+ +array-type-shift+)
                          (memref-unsigned-byte-64 base offset))))
           (incf total-words size)
           (cond ((not (eql type +object-tag-freelist-entry+))
                  (incf allocated-words size))
                 (t ; free block.
                  (setf largest-free-space (max largest-free-space size))))
           (incf offset size)))
      (values allocated-words total-words largest-free-space))))

(defun gc ()
  "Run a garbage-collection cycle."
  (when *gc-in-progress*
    (error "Nested GC?!"))
  (mezzano.supervisor:with-world-stopped
    ;; Set *GC-IN-PROGRESS* globally, not with a binding.
    (unwind-protect
         (progn
           (setf *gc-in-progress* t)
           (gc-cycle))
      (setf *gc-in-progress* nil))))

(declaim (inline immediatep))
(defun immediatep (object)
  "Return true if OBJECT is an immediate object."
  (case (%tag-field object)
    ((#.+tag-fixnum-000+ #.+tag-fixnum-001+
      #.+tag-fixnum-010+ #.+tag-fixnum-011+
      #.+tag-fixnum-100+ #.+tag-fixnum-101+
      #.+tag-fixnum-110+ #.+tag-fixnum-111+
      #.+tag-character+ #.+tag-single-float+)
     t)
    (t nil)))

(defmacro scavengef (place &environment env)
  "Scavenge PLACE. Only update PLACE if the scavenged value is different.
This is required to make the GC interrupt safe."
  (multiple-value-bind (vars vals stores setter getter)
      (get-setf-expansion place env)
    (let ((orig (gensym "ORIG"))
          (address (gensym "ADDRESS")))
      `(let* (,@(mapcar #'list vars vals)
              (,orig ,getter))
         (cond ((and (not (immediatep ,orig))
                     (eql (ldb (byte +address-tag-size+ +address-tag-shift+) (ash (%pointer-field ,orig) 4))
                     +address-tag-stack+))
                (let ((,address (ash (%pointer-field ,orig) 4)))
                  ;; Special case stack values here, to avoid chasing cycles within
                  ;; stack objects.
                  (unless (eql (logand (ash 1 +address-mark-bit+) ,address) *dynamic-mark-bit*)
                    ;; Write back first, then scan.
                    (let ((,(car stores) (%%assemble-value (logxor (ash 1 +address-mark-bit+) ,address) (%tag-field ,orig))))
                      ,setter
                      (scan-object ,orig)))))
               (t ;; Normal object, defer to scavenge-object.
                (let ((,(car stores) (scavenge-object ,orig)))
                  (when (not (eq ,orig ,(car stores)))
                    ,setter))))))))

(defun scavenge-many (address n)
  (dotimes (i n)
    (scavengef (memref-t address i))))

;;; This only scavenges the stack/registers. Scavenging the actual
;;; thread object is done by scan-thread.
(defun scavenge-current-thread ()
  ;; Grovel around in the current stack frame to grab needed stuff.
  (let* ((frame-pointer (read-frame-pointer))
         (return-address (memref-unsigned-byte-64 frame-pointer 1))
         (stack-pointer (+ frame-pointer 16)))
    (scan-thread (mezzano.supervisor:current-thread))
    (mezzano.supervisor:debug-print-line "Scav GC stack")
    (scavenge-stack stack-pointer
                    (memref-unsigned-byte-64 frame-pointer 0)
                    return-address
                    nil)))

(defun scavenge-object (object)
  "Scavenge one object, returning an updated pointer."
  (when (immediatep object)
    ;; Don't care about immediate objects, return them unchanged.
    (return-from scavenge-object object))
  (let ((address (ash (%pointer-field object) 4)))
    (ecase (ldb (byte +address-tag-size+ +address-tag-shift+) address)
      (#.+address-tag-general+
       (when (eql (logand (ash 1 +address-mark-bit+) address) *dynamic-mark-bit*)
         (return-from scavenge-object object))
       (transport-object object))
      (#.+address-tag-cons+
       (when (eql (logand (ash 1 +address-mark-bit+) address) *dynamic-mark-bit*)
         (return-from scavenge-object object))
       (transport-object object))
      (#.+address-tag-pinned+
       (mark-pinned-object object)
       object)
      (#.+address-tag-stack+
       (when (eql (logand (ash 1 +address-mark-bit+) address) *dynamic-mark-bit*)
         (return-from scavenge-object object))
       ;; FIXME: When scavenging a place, the value needs to be written back
       ;; with the mark bit correct before the object is scanned.
       (scan-object object)
       (%%assemble-value (logxor (ash 1 +address-mark-bit+) address) (%tag-field object))))))

(defun scan-error (object)
  (mezzano.supervisor:panic "Unscannable object " object))

(defun scan-generic (object size)
  "Scavenge SIZE words pointed to by OBJECT."
  (scavenge-many (ash (%pointer-field object) 4) size))

(defun scavenge-stack-n-incoming-arguments (frame-pointer stack-pointer framep
                                            layout-length n-args)
  (let ((n-values (max 0 (- n-args 5))))
    (when *gc-debug-scavenge-stack*
      (mezzano.supervisor:debug-print-line
       "  n-args " n-args
       "  n-values " n-values
       "  from " (if framep
                     (+ frame-pointer 16)
                     (+ stack-pointer (* (1+ layout-length) 8)))))
    ;; There are N-VALUES values above the return address.
    (if framep
        ;; Skip saved fp and return address.
        (scavenge-many (+ frame-pointer 16) n-values)
        ;; Skip return address and any layout values.
        (scavenge-many (+ stack-pointer (* (1+ layout-length) 8)) n-values))))

(defun scavenge-regular-stack-frame (frame-pointer stack-pointer framep
                                     layout-address layout-length
                                     incoming-arguments pushed-values)
  ;; Scan stack slots.
  (dotimes (slot layout-length)
    (multiple-value-bind (offset bit)
        (truncate slot 8)
      (when *gc-debug-scavenge-stack*
        (mezzano.supervisor:debug-print-line
         "ss: " slot " " offset ":" bit "  " (memref-unsigned-byte-8 layout-address offset)))
      (when (logbitp bit (memref-unsigned-byte-8 layout-address offset))
        (cond (framep
               (when *gc-debug-scavenge-stack*
                 (mezzano.supervisor:debug-print-line
                  "Scav stack slot " (- -1 slot)
                  "  " (lisp-object-address (memref-t frame-pointer (- -1 slot)))))
               (scavengef (memref-t frame-pointer (- -1 slot))))
              (t
               (when *gc-debug-scavenge-stack*
                 (mezzano.supervisor:debug-print-line
                  "Scav no-frame stack slot " slot
                  "  " (lisp-object-address (memref-t stack-pointer slot))))
               (scavengef (memref-t stack-pointer slot)))))))
  (dotimes (slot pushed-values)
    (when *gc-debug-scavenge-stack*
      (mezzano.supervisor:debug-print-line "Scav pv " slot))
    (scavengef (memref-t stack-pointer slot)))
  ;; Scan incoming arguments.
  (when incoming-arguments
    ;; Stored as fixnum on the stack.
    (when *gc-debug-scavenge-stack*
      (mezzano.supervisor:debug-print-line "IA in slot " (- -1 incoming-arguments)))
    (scavenge-stack-n-incoming-arguments
     frame-pointer stack-pointer framep
     layout-length
     (if framep
         (memref-t frame-pointer (- -1 incoming-arguments))
         (memref-t stack-pointer incoming-arguments)))))

(defun debug-stack-frame (framep interruptp pushed-values pushed-values-register
                          layout-address layout-length
                          multiple-values incoming-arguments block-or-tagbody-thunk)
  (when *gc-debug-scavenge-stack*
    (if framep
        (mezzano.supervisor:debug-print-line "frame")
        (mezzano.supervisor:debug-print-line "no-frame"))
    (if interruptp
        (mezzano.supervisor:debug-print-line "interrupt")
        (mezzano.supervisor:debug-print-line "no-interrupt"))
    (mezzano.supervisor:debug-print-line "pv: " pushed-values)
    (mezzano.supervisor:debug-print-line "pvr: " pushed-values-register)
    (if multiple-values
        (mezzano.supervisor:debug-print-line "mv: " multiple-values)
        (mezzano.supervisor:debug-print-line "no-multiple-values"))
    (mezzano.supervisor:debug-print-line "Layout addr: " layout-address)
    (mezzano.supervisor:debug-print-line "  Layout len: " layout-length)
    (cond (incoming-arguments
           (mezzano.supervisor:debug-print-line "ia: " incoming-arguments))
          (t (mezzano.supervisor:debug-print-line "no-incoming-arguments")))
    (if block-or-tagbody-thunk
        (mezzano.supervisor:debug-print-line "btt: " block-or-tagbody-thunk)
        (mezzano.supervisor:debug-print-line "no-btt"))))

(defun scavenge-stack (stack-pointer frame-pointer return-address interruptedp)
  (when *gc-debug-scavenge-stack* (mezzano.supervisor:debug-print-line "Scav stack..."))
  (when interruptedp
    ;; Thread has stopped due to an interrupted, stack-pointer points the start of
    ;; the thread's interrupt save area.
    ;; Examine it, then continue with normal stack scavenging.
    (when *gc-debug-scavenge-stack* (mezzano.supervisor:debug-print-line "Scav interrupted stack..."))
    (setf frame-pointer (+ stack-pointer (* 14 8))) ; sp => interrupt frame
    (let* ((other-return-address (memref-unsigned-byte-64 frame-pointer 1))
           (other-frame-pointer (memref-unsigned-byte-64 frame-pointer 0))
           (other-stack-pointer (memref-unsigned-byte-64 frame-pointer 4))
           (other-fn-address (base-address-of-internal-pointer other-return-address))
           (other-fn-offset (- other-return-address other-fn-address))
           (other-fn (%%assemble-value other-fn-address +tag-object+)))
      (when *gc-debug-scavenge-stack*
        (mezzano.supervisor:debug-print-line "oRA: " other-return-address)
        (mezzano.supervisor:debug-print-line "oFP: " other-frame-pointer)
        (mezzano.supervisor:debug-print-line "oSP: " other-stack-pointer)
        (mezzano.supervisor:debug-print-line "oFNa: " other-fn-address)
        (mezzano.supervisor:debug-print-line "oFNo: " other-fn-offset))
      ;; Unconditionally scavenge the saved data registers.
      (scavengef (memref-t frame-pointer -12)) ; r8
      (scavengef (memref-t frame-pointer -11)) ; r9
      (scavengef (memref-t frame-pointer -10)) ; r10
      (scavengef (memref-t frame-pointer -9)) ; r11
      (scavengef (memref-t frame-pointer -8)) ; r12
      (scavengef (memref-t frame-pointer -7)) ; r13
      (scavengef (memref-t frame-pointer -6)) ; rbx
      (multiple-value-bind (other-framep other-interruptp other-pushed-values other-pushed-values-register
                                         other-layout-address other-layout-length
                                         other-multiple-values other-incoming-arguments other-block-or-tagbody-thunk)
          (gc-info-for-function-offset other-fn other-fn-offset)
        (debug-stack-frame other-framep other-interruptp other-pushed-values other-pushed-values-register
                           other-layout-address other-layout-length
                           other-multiple-values other-incoming-arguments other-block-or-tagbody-thunk)
        (when (or other-interruptp
                  (and (not (eql other-pushed-values 0))
                       (or other-interruptp
                           (not other-framep)))
                  (not (eql other-pushed-values-register nil))
                  #+nil(not (or (eql other-pushed-values-register nil)
                                (eql other-pushed-values-register :rcx)))
                  (and other-multiple-values (not (eql other-multiple-values 0)))
                  (and (keywordp other-incoming-arguments) (not (eql other-incoming-arguments :rcx)))
                  other-block-or-tagbody-thunk)
          (let ((*gc-debug-scavenge-stack* t))
            (mezzano.supervisor:debug-print-line "oRA: " other-return-address)
            (mezzano.supervisor:debug-print-line "oFP: " other-frame-pointer)
            (mezzano.supervisor:debug-print-line "oSP: " other-stack-pointer)
            (mezzano.supervisor:debug-print-line "oFNa: " other-fn-address)
            (mezzano.supervisor:debug-print-line "oFNo: " other-fn-offset)
            (debug-stack-frame other-framep other-interruptp other-pushed-values other-pushed-values-register
                               other-layout-address other-layout-length
                               other-multiple-values other-incoming-arguments other-block-or-tagbody-thunk))
          (mezzano.supervisor:panic "TODO! GC SG stuff. (interrupt)"))
        (when (keywordp other-incoming-arguments)
          (when (not (eql other-incoming-arguments :rcx))
            (let ((*gc-debug-scavenge-stack* t))
              (debug-stack-frame other-framep other-interruptp other-pushed-values other-pushed-values-register
                                 other-layout-address other-layout-length
                                 other-multiple-values other-incoming-arguments other-block-or-tagbody-thunk))
            (mezzano.supervisor:panic "TODO? incoming-arguments not in RCX"))
          (setf other-incoming-arguments nil)
          (mezzano.supervisor:debug-print-line "ia-count " (memref-t frame-pointer -2))
          (scavenge-stack-n-incoming-arguments
           other-frame-pointer other-stack-pointer other-framep
           other-layout-length
           ;; RCX.
           (memref-t frame-pointer -2)))
        (scavenge-regular-stack-frame other-frame-pointer other-stack-pointer other-framep
                                      other-layout-address other-layout-length
                                      other-incoming-arguments other-pushed-values)
        (cond (other-framep
               ;; Stop after seeing a zerop frame pointer.
               (when (eql other-frame-pointer 0)
                 (when *gc-debug-scavenge-stack* (mezzano.supervisor:debug-print-line "Done scav stack."))
                 (return-from scavenge-stack))
               (psetf return-address (memref-unsigned-byte-64 other-frame-pointer 1)
                      stack-pointer (+ other-frame-pointer 16)
                      frame-pointer (memref-unsigned-byte-64 other-frame-pointer 0)))
              (t ;; No frame, carefully pick out the new values.
               ;; Frame pointer should be unchanged.
               (setf frame-pointer other-frame-pointer)
               ;; Stack pointer needs the return address popped off,
               ;; and any layout variables.
               (setf stack-pointer (+ other-stack-pointer (* (1+ other-layout-length) 8)))
               ;; Return address should be one below the stack pointer.
               (setf return-address (memref-unsigned-byte-64 stack-pointer -1)))))))
  (tagbody LOOP
     (when *gc-debug-scavenge-stack*
       (mezzano.supervisor:debug-print-line "SP: " stack-pointer)
       (mezzano.supervisor:debug-print-line "FP: " frame-pointer)
       (mezzano.supervisor:debug-print-line "RA: " return-address))
     (let* ((fn-address (base-address-of-internal-pointer return-address))
            (fn-offset (- return-address fn-address))
            (fn (%%assemble-value fn-address +tag-object+)))
       (when *gc-debug-scavenge-stack*
         (mezzano.supervisor:debug-print-line "fn: " fn-address)
         (mezzano.supervisor:debug-print-line "fnoffs: " fn-offset))
       (scavenge-object fn)
       (multiple-value-bind (framep interruptp pushed-values pushed-values-register
                                    layout-address layout-length
                                    multiple-values incoming-arguments block-or-tagbody-thunk)
           (gc-info-for-function-offset fn fn-offset)
         (when (or interruptp
                   (and (not (eql pushed-values 0))
                        (or interruptp
                            (not framep)))
                   pushed-values-register
                   (and multiple-values (not (eql multiple-values 0)))
                   (or (keywordp incoming-arguments)
                       (and incoming-arguments (not framep)))
                   block-or-tagbody-thunk)
           (let ((*gc-debug-scavenge-stack* t))
             (debug-stack-frame framep interruptp pushed-values pushed-values-register
                                layout-address layout-length
                                multiple-values incoming-arguments block-or-tagbody-thunk))
           (mezzano.supervisor:panic "TODO! GC SG stuff."))
         (scavenge-regular-stack-frame frame-pointer stack-pointer framep
                                       layout-address layout-length
                                       incoming-arguments pushed-values)
         ;; Stop after seeing a zerop frame pointer.
         (when (eql frame-pointer 0)
           (when *gc-debug-scavenge-stack* (mezzano.supervisor:debug-print-line "Done scav stack."))
           (return-from scavenge-stack))
         (if (not framep)
             (mezzano.supervisor:panic "No frame, but no end in sight?"))
         (psetf return-address (memref-unsigned-byte-64 frame-pointer 1)
                stack-pointer (+ frame-pointer 16)
                frame-pointer (memref-unsigned-byte-64 frame-pointer 0))))
     (go LOOP)))

(defun scan-thread (object)
  (when *gc-debug-scavenge-stack* (mezzano.supervisor:debug-print-line "Scav thread " object))
  ;; Scavenge various parts of the thread.
  (scavengef (mezzano.supervisor:thread-name object))
  (scavengef (mezzano.supervisor:thread-state object))
  (scavengef (mezzano.supervisor:thread-lock object))
  ;; FIXME: Mark stack.
  (scavengef (mezzano.supervisor:thread-stack object))
  (scavengef (mezzano.supervisor:thread-special-stack-pointer object))
  (scavengef (mezzano.supervisor:thread-wait-item object))
  (scavengef (mezzano.supervisor:thread-preemption-disable-depth object))
  (scavengef (mezzano.supervisor:thread-preemption-pending object))
  (scavengef (mezzano.supervisor:thread-%next object))
  (scavengef (mezzano.supervisor:thread-%prev object))
  (scavengef (mezzano.supervisor:thread-foothold-disable-depth object))
  (scavengef (mezzano.supervisor:thread-mutex-stack object))
  (scavengef (mezzano.supervisor:thread-global-next object))
  (scavengef (mezzano.supervisor:thread-global-prev object))
  ;; Only scan the thread's stack, MV area & TLS area when it's alive.
  (when (not (eql (mezzano.supervisor:thread-state object) :dead))
    (let* ((address (ash (%pointer-field object) 4))
           (stack-pointer (mezzano.supervisor:thread-stack-pointer object))
           (frame-pointer (mezzano.supervisor:thread-frame-pointer object))
           (return-address (memref-unsigned-byte-64 stack-pointer 0)))
      ;; Unconditonally scavenge the TLS area and the binding stack.
      (scavenge-many (+ address 8 (* mezzano.supervisor::+thread-mv-slots-start+ 8))
                     (- mezzano.supervisor::+thread-mv-slots-end+ mezzano.supervisor::+thread-mv-slots-start+))
      (scavenge-many (+ address 8 (* mezzano.supervisor::+thread-tls-slots-start+ 8))
                     (- mezzano.supervisor::+thread-tls-slots-end+ mezzano.supervisor::+thread-tls-slots-start+))
      (when (not (or (eql object (mezzano.supervisor:current-thread))
                     ;; Don't even think about looking at the stacks of these threads. They may run at
                     ;; any time, even with the world stopped.
                     ;; Things aren't so bad though, they (should) only contain pointers to wired objects,
                     ;; and the objects they do point to should be pointed to by other live objects.
                     (eql object sys.int::*bsp-idle-thread*)
                     (eql object sys.int::*pager-thread*)
                     (eql object sys.int::*disk-io-thread*)))
        (scavenge-stack stack-pointer frame-pointer return-address
                        (eql (+ address (* (1+ mezzano.supervisor::+thread-interrupt-save-area+) 8))
                             stack-pointer))))))

(defun gc-info-for-function-offset (function offset)
  (multiple-value-bind (info-address length)
      (function-gc-info function)
    (let ((position 0)
          ;; Defaults.
          (framep nil)
          (interruptp nil)
          (pushed-values 0)
          (pushed-values-register nil)
          (layout-address 0)
          (layout-length 0)
          (multiple-values nil)
          ;; Default to RCX here for closures & other stuff. Generally the right thing.
          ;; Stuff can override if needed.
          (incoming-arguments :rcx)
          (block-or-tagbody-thunk nil))
      ;; Macroize because the compiler would allocate an environment/lambda for this otherwise.
      (macrolet ((consume (&optional (errorp t))
                   `(progn
                      (when (>= position length)
                        ,(if errorp
                             `(mezzano.supervisor:panic "Reached end of GC Info??")
                             `(debug-stack-frame framep interruptp pushed-values pushed-values-register
                                                 layout-address layout-length
                                                 multiple-values incoming-arguments block-or-tagbody-thunk))
                        (return-from gc-info-for-function-offset
                          (values framep interruptp pushed-values pushed-values-register
                                  layout-address layout-length multiple-values
                                  incoming-arguments block-or-tagbody-thunk)))
                      (prog1 (memref-unsigned-byte-8 info-address position)
                        (incf position))))
                 (register-id (reg)
                   `(ecase ,reg
                      (0 :rax)
                      (1 :rcx)
                      (2 :rdx)
                      (3 :rbx)
                      (4 :rsp)
                      (5 :rbp)
                      (6 :rsi)
                      (7 :rdi)
                      (8 :r8)
                      (9 :r9)
                      (10 :r10)
                      (11 :r11)
                      (12 :r12)
                      (13 :r13)
                      (14 :r14)
                      (15 :r15))))
        (loop (let ((address 0))
                ;; Read first byte of address, this is where we can terminate.
                (let ((byte (consume nil))
                      (offset 0))
                  (setf address (ldb (byte 7 0) byte)
                        offset 7)
                  (when (logtest byte #x80)
                    ;; Read remaining bytes.
                    (loop (let ((byte (consume)))
                            (setf (ldb (byte 7 offset) address)
                                  (ldb (byte 7 0) byte))
                            (incf offset 7)
                            (unless (logtest byte #x80)
                              (return))))))
                (when (< offset address)
                  (debug-stack-frame framep interruptp pushed-values pushed-values-register
                                     layout-address layout-length
                                     multiple-values incoming-arguments block-or-tagbody-thunk)
                  (return-from gc-info-for-function-offset
                          (values framep interruptp pushed-values pushed-values-register
                                  layout-address layout-length multiple-values
                                  incoming-arguments block-or-tagbody-thunk)))
                ;; Read flag/pvr byte & mv-and-iabtt.
                (let ((flags-and-pvr (consume))
                      (mv-and-iabtt (consume)))
                  (setf framep (logtest flags-and-pvr #b0001))
                  (setf interruptp (logtest flags-and-pvr #b0010))
                  (if (eql (ldb (byte 4 4) flags-and-pvr) 4)
                      (setf pushed-values-register nil)
                      (setf pushed-values-register
                            (register-id (ldb (byte 4 4) flags-and-pvr))))
                  (if (eql (ldb (byte 4 0) mv-and-iabtt) 15)
                      (setf multiple-values nil)
                      (setf multiple-values (ldb (byte 4 0) mv-and-iabtt)))
                  (setf block-or-tagbody-thunk nil
                        incoming-arguments nil)
                  (when (logtest flags-and-pvr #b0100)
                    (setf block-or-tagbody-thunk :rax))
                  (when (logtest flags-and-pvr #b1000)
                    (setf incoming-arguments (if (eql (ldb (byte 4 4) mv-and-iabtt) 15)
                                                 :rcx
                                                 (ldb (byte 4 4) mv-and-iabtt)))))
                ;; Read vs32 pv.
                (let ((shift 0)
                      (value 0))
                  (loop
                     (let ((b (consume)))
                       (when (not (logtest b #x80))
                         (setf value (logior value (ash (logand b #x3F) shift)))
                         (when (logtest b #x40)
                           (setf value (- value)))
                         (return))
                       (setf value (logior value (ash (logand b #x7F) shift)))
                       (incf shift 7)))
                  (setf pushed-values value))
                ;; Read vu32 n-layout bits.
                (let ((shift 0)
                      (value 0))
                  (loop
                     (let ((b (consume)))
                       (setf value (logior value (ash (logand b #x7F) shift)))
                       (when (not (logtest b #x80))
                         (return))
                       (incf shift 7)))
                  (setf layout-length value)
                  (setf layout-address (+ info-address position))
                  ;; Consume layout bits.
                  (incf position (ceiling layout-length 8)))))))))

(defun scan-array-like (object)
  ;; Careful here. Functions with lots of GC info can have the header fall
  ;; into bignumness when read as a ub64.
  (let* ((address (ash (%pointer-field object) 4))
         (type (ldb (byte +array-type-size+ +array-type-shift+)
                    (memref-unsigned-byte-8 address 0))))
    ;; Dispatch again based on the type.
    (case type
      (#.+object-tag-array-t+
       ;; simple-vector
       ;; 1+ to account for the header word.
       (scan-generic object (1+ (ldb (byte +array-length-size+ +array-length-shift+)
                                     (memref-unsigned-byte-64 address 0)))))
      ((#.+object-tag-memory-array+
        #.+object-tag-simple-string+
        #.+object-tag-string+
        #.+object-tag-simple-array+
        #.+object-tag-array+)
       ;; Dimensions don't need to be scanned
       (scan-generic object 4))
      ((#.+object-tag-complex-rational+
        #.+object-tag-ratio+)
       (scan-generic object 3))
      (#.+object-tag-symbol+
       (scan-generic object 6))
      (#.+object-tag-structure-object+
       (when (hash-table-p object)
         (setf (hash-table-rehash-required object) 't))
       (scan-generic object (1+ (ldb (byte +array-length-size+ +array-length-shift+)
                                     (memref-unsigned-byte-64 address 0)))))
      (#.+object-tag-std-instance+
       (scan-generic object 3))
      (#.+object-tag-function-reference+
       (scan-generic object 4))
      ((#.+object-tag-function+
        #.+object-tag-closure+
        #.+object-tag-funcallable-instance+)
       (scan-function object))
      ;; Things that don't need to be scanned.
      ((#.+object-tag-array-fixnum+
        #.+object-tag-array-bit+
        #.+object-tag-array-unsigned-byte-2+
        #.+object-tag-array-unsigned-byte-4+
        #.+object-tag-array-unsigned-byte-8+
        #.+object-tag-array-unsigned-byte-16+
        #.+object-tag-array-unsigned-byte-32+
        #.+object-tag-array-unsigned-byte-64+
        #.+object-tag-array-signed-byte-1+
        #.+object-tag-array-signed-byte-2+
        #.+object-tag-array-signed-byte-4+
        #.+object-tag-array-signed-byte-8+
        #.+object-tag-array-signed-byte-16+
        #.+object-tag-array-signed-byte-32+
        #.+object-tag-array-signed-byte-64+
        #.+object-tag-array-single-float+
        #.+object-tag-array-double-float+
        #.+object-tag-array-short-float+
        #.+object-tag-array-long-float+
        #.+object-tag-array-complex-single-float+
        #.+object-tag-array-complex-double-float+
        #.+object-tag-array-complex-short-float+
        #.+object-tag-array-complex-long-float+
        #.+object-tag-array-xmm-vector+
        #.+object-tag-bignum+
        #.+object-tag-double-float+
        #.+object-tag-short-float+
        #.+object-tag-long-float+
        ;; not complex-rational or ratio, they may hold other numbers.
        #.+object-tag-complex-single-float+
        #.+object-tag-complex-double-float+
        #.+object-tag-complex-short-float+
        #.+object-tag-complex-long-float+
        #.+object-tag-xmm-vector+
        #.+object-tag-unbound-value+))
      (#.+object-tag-thread+
       (scan-thread object))
      (t (scan-error object)))))

(defun scan-function (object)
  ;; Scan the constant pool.
  (let* ((address (ash (%pointer-field object) 4))
         (mc-size (* (memref-unsigned-byte-16 address 1) 16))
         (pool-size (memref-unsigned-byte-16 address 2)))
    (scavenge-many (+ address mc-size) pool-size)))

(defun scan-object (object)
  "Scan one object, updating pointer fields."
  (case (%tag-field object)
    (#.+tag-cons+
     (scan-generic object 2))
    (#.+tag-object+
     (scan-array-like object))
    (t (scan-error object))))

(defun transport-error (object)
  (mezzano.supervisor:panic "Untransportable object " object))

(defun transport-object (object)
  "Transport LENGTH words from oldspace to newspace, returning
a pointer to the new object. Leaves a forwarding pointer in place."
  (let* ((length nil)
         (address (ash (%pointer-field object) 4))
         (first-word (memref-t address 0))
         (new-address nil))
    ;; Check for a GC forwarding pointer.
    ;; Do this before getting the length.
    (when (eql (%tag-field first-word) +tag-gc-forward+)
      (return-from transport-object
        (%%assemble-value (ash (%pointer-field first-word) 4)
                          (%tag-field object))))
    (setf length (object-size object))
    (when (not length)
      (transport-error object))
    ;; Update meters.
    (incf *objects-copied*)
    (incf *words-copied* length)
    ;; Find a new location.
    (cond ((consp object)
           (setf new-address (logior (ash +address-tag-cons+ +address-tag-shift+)
                                     *cons-area-bump*
                                     *dynamic-mark-bit*))
           (incf *cons-area-bump* (* length 8)))
          (t
           (setf new-address (logior (ash +address-tag-general+ +address-tag-shift+)
                                     *general-area-bump*
                                     *dynamic-mark-bit*))
           (incf *general-area-bump* (* length 8))
           (when (oddp length)
             (setf (memref-t new-address length) 0)
             (incf *general-area-bump* 8))))
    ;; Energize!
    (%fast-copy new-address address (* length 8))
    ;; Leave a forwarding pointer.
    (setf (memref-t address 0) (%%assemble-value new-address +tag-gc-forward+))
    ;; Complete! Return the new object
    (%%assemble-value new-address (%tag-field object))))

(defun object-size (object)
  (case (%tag-field object)
    ;; FIXME? conses are 4 words when not in the cons area.
    (#.+tag-cons+ 2)
    (#.+tag-object+
     (let* ((header (%array-like-ref-unsigned-byte-64 object -1))
            (length (ldb (byte +array-length-size+ +array-length-shift+) header))
            (type (ldb (byte +array-type-size+ +array-type-shift+) header)))
       ;; Dispatch again based on the type.
       (case type
         ((#.+object-tag-array-t+
           #.+object-tag-array-fixnum+
           #.+object-tag-structure-object+)
          ;; simple-vector, std-instance or structure-object.
          ;; 1+ to account for the header word.
          (1+ length))
         ((#.+object-tag-array-bit+
           #.+object-tag-array-signed-byte-1+)
          (1+ (ceiling length 64)))
         ((#.+object-tag-array-unsigned-byte-2+
           #.+object-tag-array-signed-byte-2+)
          (1+ (ceiling length 32)))
         ((#.+object-tag-array-unsigned-byte-4+
           #.+object-tag-array-signed-byte-4+)
          (1+ (ceiling length 16)))
         ((#.+object-tag-array-unsigned-byte-8+
           #.+object-tag-array-signed-byte-8+)
          (1+ (ceiling length 8)))
         ((#.+object-tag-array-unsigned-byte-16+
           #.+object-tag-array-signed-byte-16+
           #.+object-tag-array-short-float+)
          (1+ (ceiling length 4)))
         ((#.+object-tag-array-unsigned-byte-32+
           #.+object-tag-array-signed-byte-32+
           #.+object-tag-array-single-float+
           #.+object-tag-array-complex-short-float+)
          (1+ (ceiling length 2)))
         ((#.+object-tag-array-unsigned-byte-64+
           #.+object-tag-array-signed-byte-64+
           #.+object-tag-array-double-float+
           #.+object-tag-array-complex-single-float+
           #.+object-tag-bignum+)
          (1+ length))
         ((#.+object-tag-array-long-float+
           #.+object-tag-array-complex-double-float+
           #.+object-tag-array-xmm-vector+)
          (1+ (* length 2)))
         ((#.+object-tag-array-complex-long-float+)
          (1+ (* length 4)))
         (#.+object-tag-double-float+
          2)
         (#.+object-tag-long-float+
          4)
         (#.+object-tag-short-float+
          2)
         (#.+object-tag-complex-rational+
          4)
         (#.+object-tag-complex-short-float+
          2)
         (#.+object-tag-complex-single-float+
          2)
         (#.+object-tag-complex-double-float+
          4)
         (#.+object-tag-complex-long-float+
          8)
         (#.+object-tag-ratio+
          4)
         (#.+object-tag-xmm-vector+
          4)
         (#.+object-tag-symbol+
          6)
         (#.+object-tag-std-instance+
          3)
         (#.+object-tag-function-reference+
          4)
         ((#.+object-tag-function+
           #.+object-tag-closure+
           #.+object-tag-funcallable-instance+)
          ;; The size of a function is the sum of the MC, the GC info and the constant pool.
          (ceiling (+ (* (ldb (byte 16 8) length) 16)  ; mc size
                      (* (ldb (byte 16 24) length) 8)  ; pool size
                      (ldb (byte 16 40) length)) ; gc-info size.
                   8))
         ((#.+object-tag-memory-array+
           #.+object-tag-simple-string+
           #.+object-tag-string+
           #.+object-tag-simple-array+
           #.+object-tag-array+)
          (+ 4 length))
         (#.+object-tag-unbound-value+
          2)
         (#.+object-tag-thread+
          512))))))

(defun mark-pinned-object (object)
  (let ((address (ash (%pointer-field object) 4)))
    (cond ((consp object)
           ;; The object header for conses is 16 bytes behind the address.
           (when (not (eql (ldb (byte +array-type-size+ +array-type-shift+)
                                (memref-unsigned-byte-64 address -2))
                           +object-tag-cons+))
             (mezzano.supervisor:debug-print-line "Invalid pinned cons " object))
           (when (not (eql (logand (memref-unsigned-byte-64 address -2)
                                   +array-like-mark-bit+)
                           *pinned-mark-bit*))
             ;; Not marked, mark it.
             (setf (memref-unsigned-byte-64 address -2) (logior (logand (memref-unsigned-byte-64 address -2)
                                                                        (lognot +array-like-mark-bit+))
                                                                *pinned-mark-bit*))
             ;; And scan.
             (scan-object object)))
          (t (when (eql (sys.int::%object-tag object) +object-tag-freelist-entry+)
               (mezzano.supervisor:debug-print-line
                "Marking freelist entry " object))
             (when (not (eql (logand (memref-unsigned-byte-64 address 0)
                                          +array-like-mark-bit+)
                                  *pinned-mark-bit*))
               ;; Not marked, mark it.
               (setf (memref-unsigned-byte-64 address 0) (logior (logand (memref-unsigned-byte-64 address 0)
                                                                         (lognot +array-like-mark-bit+))
                                                                 *pinned-mark-bit*))
               ;; And scan.
               (scan-object object))))))

#+(or)(defun sweep-stacks ()
  (mezzano.supervisor:debug-print-line "sweeping stacks")
  (do* ((reversed-result nil)
        (last-free nil)
        (current *gc-stack-ranges* next)
        (next (cdr current) (cdr current)))
       ((endp current)
        ;; Reverse the result list.
        (do ((result nil)
             (i reversed-result))
            ((endp i)
             (setf *gc-stack-ranges* result))
          (psetf i (cdr i)
                 (cdr i) result
                 result i)))
    (cond ((gc-stack-range-marked (first current))
           ;; This one is allocated & still in use.
           (assert (gc-stack-range-allocated (first current)))
           (setf (rest current) reversed-result
                 reversed-result current))
          ((and last-free
                (eql (gc-stack-range-end last-free)
                     (gc-stack-range-start (first current))))
           ;; Free and can be merged.
           (setf (gc-stack-range-end last-free)
                 (gc-stack-range-end (first current))))
          (t ;; Free, but no last-free.
           (setf last-free (first current)
                 (gc-stack-range-allocated (first current)) nil
                 (rest current) reversed-result
                 reversed-result current)))))

(defun scavenge-dynamic ()
  (let ((general-finger 0)
        (cons-finger 0))
    (loop
       (mezzano.supervisor:debug-print-line
        "General. Limit: " *general-area-limit*
        "  Bump: " *general-area-bump*
        "  Curr: " general-finger)
       (mezzano.supervisor:debug-print-line
        "Cons.    Limit: " *cons-area-limit*
        "  Bump: " *cons-area-bump*
        "  Curr: " cons-finger)
       ;; Stop when both area sets have been fully scavenged.
       (when (and (eql general-finger *general-area-bump*)
                  (eql cons-finger *cons-area-bump*))
         (return))
       (mezzano.supervisor:debug-print-line "Scav main seq")
       ;; Scavenge general area.
       (loop
          (when (eql general-finger *general-area-bump*)
            (return))
          (let* ((object (%%assemble-value (logior general-finger
                                                   (ash +address-tag-general+ +address-tag-shift+)
                                                   *dynamic-mark-bit*)
                                           +tag-object+))
                 (size (object-size object)))
            (when (oddp size)
              (incf size))
            (scan-object object)
            (incf general-finger (* size 8))))
       ;; Scavenge cons area.
       (loop
          (when (eql cons-finger *cons-area-bump*)
            (return))
          ;; Cons region is just pointers.
          (let ((addr (logior cons-finger
                              (ash +address-tag-cons+ +address-tag-shift+)
                              *dynamic-mark-bit*)))
            (scavengef (memref-t addr 0))
            (scavengef (memref-t addr 1)))
          (incf cons-finger 16)))))

(defun size-of-pinned-area-allocation (address)
  "Return the size of an allocation in the wired or pinned area."
  (let ((type (ash (memref-unsigned-byte-8 address 0) (- +array-type-shift+))))
    (case type
      (#.+object-tag-cons+ 4)
      (#.+object-tag-freelist-entry+ (ash (memref-unsigned-byte-64 address 0)
                                          (- +array-length-shift+)))
      (t (object-size (%%assemble-value address +tag-object+))))))

(defun align-up (value boundary)
  (logand (+ value (1- boundary)) (lognot (1- boundary))))

(defun find-next-free-object (start limit)
  (loop
     (when (>= start limit)
       (return nil))
     (when (not (eql (logand (memref-unsigned-byte-64 start 0) +array-like-mark-bit+)
                     *pinned-mark-bit*))
       ;; Not marked, must be free.
       (return start))
     (incf start (* (align-up (size-of-pinned-area-allocation start) 2) 8))))

(defun make-freelist-header (len)
  (logior *pinned-mark-bit*
          (ash +object-tag-freelist-entry+ +array-type-shift+)
          (ash (align-up len 2) +array-length-shift+)))

(defun rebuild-freelist (freelist-symbol base limit)
  "Sweep the pinned/wired area chain and rebuild the freelist."
  (mezzano.supervisor:debug-print-line "rebuild freelist " freelist-symbol)
  ;; Set initial freelist entry.
  (let ((initial (find-next-free-object base limit)))
    (when (not initial)
      (setf (symbol-value freelist-symbol) '())
      (when *gc-debug-freelist-rebuild*
        (mezzano.supervisor:debug-print-line "done (empty)"))
      (return-from rebuild-freelist))
    (when *gc-debug-freelist-rebuild*
      (mezzano.supervisor:debug-print-line "initial: " initial))
    (setf (memref-unsigned-byte-64 initial 0) (make-freelist-header (size-of-pinned-area-allocation initial))
          (memref-t initial 1) '()
          (symbol-value freelist-symbol) initial))
  ;; Build the freelist.
  (let ((current (symbol-value freelist-symbol)))
    (loop
       ;; Expand this entry as much as possible.
       (let* ((len (ash (memref-unsigned-byte-64 current 0) (- +array-length-shift+)))
              (next-addr (+ current (* len 8))))
         (when *gc-debug-freelist-rebuild*
           (mezzano.supervisor:debug-print-line "len: " len "  next: " next-addr))
         (when (>= next-addr limit)
           (when *gc-debug-freelist-rebuild*
             (mezzano.supervisor:debug-print-line "done (limit)"))
           (when mezzano.runtime::*paranoid-allocation*
             (dotimes (i (- len 2))
               (setf (memref-signed-byte-64 current (+ i 2)) -1)))
           (return))
         ;; Test the mark bit.
         (cond ((eql (logand (memref-unsigned-byte-64 next-addr 0) +array-like-mark-bit+)
                     *pinned-mark-bit*)
                ;; Is marked, finish this entry and start the next one.
                (setf next-addr (find-next-free-object current limit))
                (when (not next-addr)
                  (when *gc-debug-freelist-rebuild*
                    (mezzano.supervisor:debug-print-line "done"))
                  (when mezzano.runtime::*paranoid-allocation*
                    (dotimes (i (- len 2))
                      (setf (memref-signed-byte-64 current (+ i 2)) -1)))
                  (return))
                (when *gc-debug-freelist-rebuild*
                  (mezzano.supervisor:debug-print-line "adv: " next-addr))
                (setf (memref-unsigned-byte-64 next-addr 0) (make-freelist-header (size-of-pinned-area-allocation next-addr))
                      (memref-t next-addr 1) '())
                (setf (memref-t current 1) next-addr
                      current next-addr))
               (t ;; Not marked, expand to cover this entry.
                (setf (memref-unsigned-byte-64 current 0) (make-freelist-header (+ len (size-of-pinned-area-allocation next-addr))))))))))

(defun gc-cycle ()
  (mezzano.supervisor::set-gc-light t)
  (mezzano.supervisor:debug-print-line "GC in progress...")
  ;; Clear per-cycle meters
  (setf *objects-copied* 0
        *words-copied* 0)
  ;; Flip.
  (psetf *dynamic-mark-bit* (logxor *dynamic-mark-bit* (ash 1 +address-mark-bit+))
         *pinned-mark-bit* (logxor *pinned-mark-bit* +array-like-mark-bit+)
         *current-stack-mark-bit* (logxor *current-stack-mark-bit* (ash 1 (- +address-mark-bit+ +n-fixnum-bits+))))
  (setf *general-area-bump* 0
        *cons-area-bump* 0)
  ;; Unprotect newspace.
  (mezzano.supervisor:protect-memory-range (logior *dynamic-mark-bit*
                                                   (ash +address-tag-general+ +address-tag-shift+))
                                           *general-area-limit*
                                           (logior +block-map-present+
                                                   +block-map-writable+
                                                   +block-map-zero-fill+))
  (mezzano.supervisor:protect-memory-range (logior *dynamic-mark-bit*
                                                   (ash +address-tag-cons+ +address-tag-shift+))
                                           *cons-area-limit*
                                           (logior +block-map-present+
                                                   +block-map-writable+
                                                   +block-map-zero-fill+))
  (mezzano.supervisor:debug-print-line "Scav roots")
  ;; Scavenge NIL to start things off.
  (scavenge-object 'nil)
  ;; And various important other roots.
  (scavenge-object (%unbound-value))
  (scavenge-object (%unbound-tls-slot))
  (scavenge-object (%undefined-function))
  (scavenge-object (%closure-trampoline))
  ;; Scavenge the current thread's stack.
  (scavenge-current-thread)
  ;; Now do the bulk of the work by scavenging the dynamic areas.
  ;; No scavenging can take place after this.
  (scavenge-dynamic)
  ;; Inhibit access to oldspace.
  (mezzano.supervisor:protect-memory-range (logior (logxor *dynamic-mark-bit* (ash 1 +address-mark-bit+))
                                                   (ash +address-tag-general+ +address-tag-shift+))
                                           *general-area-limit*
                                           +block-map-zero-fill+)
  (mezzano.supervisor:protect-memory-range (logior (logxor *dynamic-mark-bit* (ash 1 +address-mark-bit+))
                                                   (ash +address-tag-cons+ +address-tag-shift+))
                                           *cons-area-limit*
                                           +block-map-zero-fill+)
  ;; Rebuild freelists.
  (rebuild-freelist '*wired-area-freelist* (* 2 1024 1024) *wired-area-bump*)
  (rebuild-freelist '*pinned-area-freelist* (* 2 1024 1024 1024) *pinned-area-bump*)
  ;; Trim the dynamic areas.
  (let ((new-limit (align-up *general-area-bump* #x200000)))
    (mezzano.supervisor:release-memory-range (logior new-limit
                                                     (ash +address-tag-general+ +address-tag-shift+))
                                             (- *general-area-limit* new-limit))
    (mezzano.supervisor:release-memory-range (logior (ash 1 +address-mark-bit+)
                                                     new-limit
                                                     (ash +address-tag-general+ +address-tag-shift+))
                                             (- *general-area-limit* new-limit))
    (setf *general-area-limit* new-limit))
  (let ((new-limit (align-up *cons-area-bump* #x200000)))
    (mezzano.supervisor:release-memory-range (logior new-limit
                                                     (ash +address-tag-cons+ +address-tag-shift+))
                                             (- *cons-area-limit* new-limit))
    (mezzano.supervisor:release-memory-range (logior (ash 1 +address-mark-bit+)
                                                     new-limit
                                                     (ash +address-tag-cons+ +address-tag-shift+))
                                             (- *cons-area-limit* new-limit))
    (setf *cons-area-limit* new-limit))
  (setf *memory-expansion-remaining* *memory-expansion*)
  (mezzano.supervisor:debug-print-line "GC complete")
  (mezzano.supervisor::set-gc-light nil))

(defun base-address-of-internal-pointer (address)
  "Find the base address of the object pointed to be ADDRESS.
Address should be an internal pointer to a live object in static space.
No type information will be provided."
  (flet ((search (start limit)
           (let ((offset start))
             (loop
                (when (>= offset limit)
                  (return))
                (let* ((type (ash (memref-unsigned-byte-8 offset 0) (- +array-type-shift+)))
                       (size (size-of-pinned-area-allocation offset)))
                  (when (and (not (eql type +object-tag-freelist-entry+))
                             (<= offset address (+ offset (* size 8) -1)))
                    (return-from base-address-of-internal-pointer
                      offset))
                  (incf offset (* (align-up size 2) 8)))))))
    ;; Search wired area.
    (search (* 2 1024 1024) *wired-area-bump*)
    ;; Search pinned area.
    (search (* 2 1024 1024 1024) *pinned-area-bump*)))
