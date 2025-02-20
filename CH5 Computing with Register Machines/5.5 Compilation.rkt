#lang planet neil/sicp


;; the compiler

(define (compile exp target linkage)
  (cond ((self-evaluating? exp) (compile-self-evaluating exp target linkage))
        ((quoted? exp) (compile-quoted exp target linkage))
        ((variable? exp) (compile-variable exp target linkage))
        ((assignment? exp) (compile-assignment exp target linkage))
        ((definition? exp) (compile-definition exp target linkage))
        ((if? exp) (compile-if exp target linkage))
        ((lambda? exp) (compile-lambda exp target linkage))
        ((begin? exp) (compile-sequence (begin-actions exp) target linkage))
        ((cond? exp) (compile (cond->if exp) target linkage))
        ((application? exp) (compile-application exp target linkage))
        (else (error "Unknown expression type -- COMPILE" exp))))



;; combining instruction sequences

(define (make-instruction-sequence needs modifies statements) (list needs modifies statements))

(define (empty-instruction-sequence) (make-instruction-sequence '() '() '()))

(define (registers-needed s) (if (symbol? s) '() (car s)))

(define (registers-modified s) (if (symbol? s) '() (cadr s)))

(define (statements s) (if (symbol? s) (list s) (caddr s)))

(define (memq item x)
  (cond ((null? x) #f)
        ((eq? (car x) item) x)
        (else (memq item (cdr x)))))

(define (needs-register? seq reg) (memq reg (registers-needed seq)))

(define (modifies-register? seq reg) (memq reg (registers-modified seq)))



;; appending instructions sequences

(define (append-instruction-sequences . seqs)
  (define (append-2-sequences seq1 seq2)
    (make-instruction-sequence
     
     (list-union (registers-needed seq1)
                 (list-difference (registers-needed seq2)
                                  (registers-modified seq1)))
     
     (list-union (registers-modified seq1)
                 (registers-modified seq2))
     
     (append (statements seq1) (statements seq2))))
  (define (append-seq-list seqs)
    (if (null? seqs)
        (empty-instruction-sequence)
        (append-2-sequences (car seqs)
                            (append-seq-list (cdr seqs)))))
  (append-seq-list seqs))


(define (list-union s1 s2)
  (cond ((null? s1) s2)
        ((memq (car s1) s2) (list-union (cdr s1) s2))
        (else (cons (car s1) (list-union (cdr s1) s2)))))

(define (list-difference s1 s2)
  (cond ((null? s1) '())
        ((memq (car s1) s2) (list-difference (cdr s1) s2))
        (else (cons (car s1) (list-difference (cdr s1) s2)))))



;; preserving

(define (preserving regs seq1 seq2)
  (if (null? regs)
      (append-instruction-sequences seq1 seq2)
      (let ((first-reg (car regs)))
        (if (and (needs-register? seq2 first-reg)
                 (modifies-register? seq1 first-reg))
            (preserving (cdr regs)
                        
                        (make-instruction-sequence
                         (list-union (list first-reg) (registers-needed seq1))
                         (list-difference (registers-modified seq1) (list first-reg))
                         (append `((save ,first-reg))
                                 (statements seq1)
                                 `((restore ,first-reg))))
                        
                        seq2)
            (preserving (cdr regs) seq1 seq2)))))



;; append procedure body to another sequence

(define (tack-on-instruction-sequence seq body-seq)
  (make-instruction-sequence
   (registers-needed seq)
   (registers-modified seq)
   (append (statements seq) (statements body-seq))))



;; append two alternative branchs following a test

(define (parallel-instruction-sequences seq1 seq2)
  (make-instruction-sequence
   (list-union (registers-needed seq1)
               (registers-needed seq2))
   (list-union (registers-modified seq1)
               (registers-modified seq2))
   (append (statements seq1) (statements seq2))))



; ex 5.31

;  (f 'x 'y)        all saves and restores are superfluous
;  ((f) 'x 'y)      ditto, because 'x and 'y are independent of env
;  (f (g 'x) y)     save and restore proc, env and argl, because of (g 'x) and y
;  (f (g 'x) 'y)    save and restore proc and argl, because 'y is independent of env



;; ex 5.32
;
; a. ev-application and related blocks in the EC-evaluator are modified
;
; b. 1. testing special cases adds additional overhead
;    2. some optimizations of compiler can't be done by adding rules to the interpreter,
;       e.g., the interpreter would examine expressions everytime for dispatching.




;; compiling linkage code

(define (compile-linkage linkage)
  (cond ((eq? linkage 'return)
         (make-instruction-sequence
          '(continue) '()
          '((goto (reg continue)))))
        ((eq? linkage 'next) (empty-instruction-sequence))
        (else (make-instruction-sequence
               '() '()
               `((goto (label ,linkage)))))))


(define (end-with-linkage linkage instruction-sequence)
  (preserving '(continue)
              instruction-sequence
              (compile-linkage linkage)))



;; compiling simple expressions

(define (compile-self-evaluating exp target linkage)
  (end-with-linkage linkage
                    (make-instruction-sequence
                     '() (list target)
                     `((assign ,target (const ,exp))))))


(define (compile-quoted exp target linkage)
  (end-with-linkage linkage
                    (make-instruction-sequence
                     '() (list target)
                     `((assign ,target (const ,(text-of-quotation exp)))))))


(define (compile-variable exp target linkage)
  (end-with-linkage linkage
                    (make-instruction-sequence
                     '(env) (list target)
                     `((assign ,target
                               (op lookup-variable-value)
                               (const ,exp)
                               (reg env))))))



;; compiling assignments and definitions

(define (compile-assignment exp target linkage)
  (let ((var (assignment-variable exp))
        (get-value-code (compile (assignment-value exp) 'val 'next)))
    (end-with-linkage linkage
                      (preserving '(env)
                                  get-value-code
                                  (make-instruction-sequence
                                   '(env val) (list target)
                                   `((perform (op set-variable-value!) (const ,var) (reg val) (reg env))
                                     (assign ,target (const ok))))))))


(define (compile-definition exp target linkage)
  (let ((var (definition-variable exp))
        (get-value-code (compile (definition-value exp) 'val 'next)))
    (end-with-linkage linkage
                      (preserving '(env)
                                  get-value-code
                                  (make-instruction-sequence
                                   '(env val) (list target)
                                   `((perform (op define-variable!) (const ,var) (reg val) (reg env))
                                     (assign ,target (const ok))))))))



;; generate labels

(define label-counter 0)

(define (new-label-number)
  (set! label-counter (+ 1 label-counter))
  label-counter)

(define (make-label name)
  (string->symbol
   (string-append (symbol->string name)
                  (number->string (new-label-number)))))



;; compiling conditional expressions

(define (compile-if exp target linkage)
  (let ((t-branch (make-label 'true-branch))
        (f-branch (make-label 'false-branch))                    
        (after-if (make-label 'after-if)))
    (let ((consequent-linkage (if (eq? linkage 'next) after-if linkage)))
      (let ((p-code (compile (if-predicate exp) 'val 'next))
            (c-code (compile (if-consequent exp) target consequent-linkage))
            (a-code (compile (if-alternative exp) target linkage)))
        (preserving '(env continue)
                    
                    ; <seq 1>
                    p-code
                    
                    ; <seq 2>
                    (append-instruction-sequences
                     ; <seq 2.1>
                     (make-instruction-sequence
                      '(val) '()
                      `((test (op false?) (reg val))
                        (branch (label ,f-branch))))
                     ; <seq 2.2>
                     (parallel-instruction-sequences
                      (append-instruction-sequences t-branch c-code)
                      (append-instruction-sequences f-branch a-code))
                     ; <seq 2.3>
                     after-if))))))



;; compiling sequences

(define (compile-sequence seq target linkage)
  (if (last-exp? seq)
      (compile (first-exp seq) target linkage)
      (preserving '(env continue)
                  (compile (first-exp seq) target 'next)
                  (compile-sequence (rest-exps seq) target linkage))))



;; representing compiled procedures

(define (make-compiled-procedure entry env) (list 'compiled-procedure entry env))

(define (compiled-procedure? proc) (tagged-list? proc 'compiled-procedure))

(define (compiled-procedure-entry c-proc) (cadr c-proc))

(define (compiled-procedure-env c-proc) (caddr c-proc))



;; compiling lambda expressions

(define (compile-lambda exp target linkage)
  (let ((proc-entry (make-label 'entry))
        (after-lambda (make-label 'after-lambda)))
    (let ((lambda-linkage (if (eq? linkage 'next) after-lambda linkage)))
      (append-instruction-sequences
       
       (tack-on-instruction-sequence
        
        (end-with-linkage lambda-linkage
                          (make-instruction-sequence
                           '(env) (list target)
                           `((assign ,target (op make-compiled-procedure) (label ,proc-entry) (reg env)))))
        
        (compile-lambda-body exp proc-entry))
       
       after-lambda))))


(define (compile-lambda-body exp proc-entry)
  (let ((formals (lambda-parameters exp)))
    (append-instruction-sequences
     (make-instruction-sequence '(env proc argl) '(env)
                                `(,proc-entry
                                  (assign env (op compiled-procedure-env) (reg proc))
                                  (assign env (op extend-environment) (const ,formals) (reg argl) (reg env))))
     (compile-sequence (lambda-body exp) 'val 'return))))



;; compiling applications

(define (compile-application exp target linkage)
  (let ((proc-code (compile (operator exp) 'proc 'next))
        (operand-codes
         (map (lambda (operand) (compile operand 'val 'next))
              (operands exp))))
    (preserving '(env continue)
                proc-code
                (preserving '(proc continue)
                            (construct-arglist operand-codes)
                            (compile-procedure-call target linkage)))))



;; compiling operands and construct argument list

(define (construct-arglist operand-codes)
  (let ((operand-codes (reverse operand-codes)))
    (if (null? operand-codes)
        (make-instruction-sequence
         '() '(argl)
         '((assign argl (const ()))))
        (let ((code-to-get-last-arg
               (append-instruction-sequences
                (car operand-codes)
                (make-instruction-sequence
                 '(val) '(argl)
                 '((assign argl (op list) (reg val)))))))
          (if (null? (cdr operand-codes))
              code-to-get-last-arg
              (preserving '(env)
                          code-to-get-last-arg
                          (code-to-get-rest-args (cdr operand-codes))))))))


(define (code-to-get-rest-args operand-codes)
  (let ((code-for-next-arg
         (preserving '(argl)
                     (car operand-codes)
                     (make-instruction-sequence
                      '(val argl) '(argl)
                      '((assign argl (op cons) (reg val) (reg argl)))))))
    (if (null? (cdr operand-codes))
        code-for-next-arg
        (preserving '(env)
                    code-for-next-arg
                    (code-to-get-rest-args (cdr operand-codes))))))



;; compiling procedure calls

(define (compile-procedure-call target linkage)
  (let ((primitive-branch (make-label 'primitive-branch))
        (compiled-branch (make-label 'compiled-branch))
        (after-call (make-label 'after-call)))
    (let ((compiled-linkage (if (eq? linkage 'next) after-call linkage)))
      (append-instruction-sequences
       
       ; <seq 1>
       (make-instruction-sequence
        '(proc) '()
        `((test (op primitive-procedure?) (reg proc))
          (branch (label ,primitive-branch))))
       
       ; <seq 2>
       (parallel-instruction-sequences
        
        ; <seq 2.1>
        (append-instruction-sequences
         compiled-branch
         (compile-proc-appl target compiled-linkage))
        
        ; <seq 2.2>
        (append-instruction-sequences
         primitive-branch
         (end-with-linkage linkage
                           (make-instruction-sequence
                            '(proc argl)
                            (list target)
                            `((assign ,target (op apply-primitive-procedure) (reg proc) (reg argl)))))))
       
       ; <seq 3>
       after-call))))



;; compiling compiled procedures

(define all-regs '(env proc val argl continue))

(define (compile-proc-appl target linkage)
  (cond ((and (eq? target 'val) (not (eq? linkage 'return)))
         (make-instruction-sequence
          '(proc) all-regs
          `((assign continue (label ,linkage))
            (assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val)) (not (eq? linkage 'return)))
         (let ((proc-return (make-label 'proc-return)))
           (make-instruction-sequence
            '(proc) all-regs
            `((assign continue (label ,proc-return))
              (assign val (op compiled-procedure-entry) (reg proc))
              (goto (reg val))
              ,proc-return
              (assign ,target (reg val))
              (goto (label ,linkage))))))
        ((and (eq? target 'val) (eq? linkage 'return))
         (make-instruction-sequence
          '(proc continue) all-regs
          '((assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val)) (eq? linkage 'return))
         (error "return linkage, target not val -- COMPILE" target))))




;; test

;; use pretty-display of Racket

(display (compile
          '(define (factorial n)
             (if (= n 1)
                 1
                 (* (factorial (- n 1)) n)))
          'val
          'next))


(set! label-counter 0)
(newline)
(newline)



;; compilation result of the factorial procedure definition

(define compiled-factorial-rec
  '(
    ; construct the procedure and skip over code for the procedure body 
    (assign val (op make-compiled-procedure) (label entry1) (reg env))
    (goto (label after-lambda2))
    
    ; calls to factorial will enter here
    entry1
    (assign env (op compiled-procedure-env) (reg proc))
    (assign env (op extend-environment) (const (n)) (reg argl) (reg env))
    
    ; begin actual procedure body
    (save continue)
    (save env)
    
    ; compute (= n 1)
    (assign proc (op lookup-variable-value) (const =) (reg env))
    
    (assign val (const 1))
    (assign argl (op list) (reg val))
    (assign val (op lookup-variable-value) (const n) (reg env))
    (assign argl (op cons) (reg val) (reg argl))
    
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch6))
    
    compiled-branch7
    (assign continue (label after-call8))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch6
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (= n 1)
    after-call8
    
    (restore env)
    (restore continue)
    
    (test (op false?) (reg val))
    (branch (label false-branch4))
    
    true-branch3
    (assign val (const 1))
    (goto (reg continue))
    
    false-branch4
    ; compute and return (* factorial (- n 1)) n)
    (assign proc (op lookup-variable-value) (const *) (reg env))
    (save continue)
    ; save * procedure
    (save proc)  
    (assign val (op lookup-variable-value) (const n) (reg env))
    (assign argl (op list) (reg val))
    ; save partial argument list for *
    (save argl)  
    
    ; compute (factorial (- n 1)), which is the other argument for * 
    (assign proc (op lookup-variable-value) (const factorial) (reg env))
    ; save factorial procedure
    (save proc)
    
    ; compute (- n 1), which is the argument for factorial
    (assign proc (op lookup-variable-value) (const -) (reg env))
    
    (assign val (const 1))
    (assign argl (op list) (reg val))
    (assign val (op lookup-variable-value) (const n) (reg env))
    (assign argl (op cons) (reg val) (reg argl))
    
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch9))
    
    compiled-branch10
    (assign continue (label after-call11))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch9
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (- n 1)
    after-call11  
    (assign argl (op list) (reg val))
    (restore proc)
    
    ; apply factorial
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch12))
    
    compiled-branch13
    (assign continue (label after-call14))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch12
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (factorial (- n 1))
    after-call14
    ; restore partial argument list for *
    (restore argl)  
    (assign argl (op cons) (reg val) (reg argl))
    ; restore *
    (restore proc)  
    (restore continue)
    
    ; apply * and return its value
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch15))
    
    compiled-branch16
    ; note that a compound procedure here is called tail-recursively
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch15
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    (goto (reg continue))
    
    after-call17
    after-if5
    after-lambda2
    
    ;; assign the procedure to the variable factorial
    (perform (op define-variable!) (const factorial) (reg val) (reg env))
    (assign val (const ok))
    ))




; ex 5.33

; only two blocks are changed false-branch4 and after-call9, and
; there's no difference in efficiency.


false-branch4
(assign proc (op lookup-variable-value) (const *) (reg env))
(save continue)
(save proc)
; the following 3 lines are changed to (save env)
;* (assign val (op lookup-variable-value) (const n) (reg env))
;* (assign argl (op list) (reg val))
;* (save argl) 
(save env) ;*


after-call9
; instead of (restore argl), the following 3 lines are changed
(assign argl (op list) (reg val))                           ;*
(restore env)                                               ;*
(assign val (op lookup-variable-value) (const n) (reg env)) ;*
(assign argl (op cons) (reg val) (reg argl))


; The difference resides in the if alternative, where we firstly compute
; (factorial (- n 1)), then look up the value of n, since n is changed
; when evaluating (- n 1), we need to save and restore env. We accumulate
; argl after having evaluated (factorial (- n 1)), so no nedd to save argl.
;
;
; The orignal factorial firstly looks up n then computes (factorial (- n 1)),
; since argl may be changed by evaluating (factorial (- n 1)), we need to
; save and restore argl to accumulate the arguments.

(display (compile
          '(define (factorial-alt n)
             (if (= n 1)
                 1
                 (* n (factorial-alt (- n 1)))))
          'val
          'next))


(set! label-counter 0)
(newline)
(newline)





; ex 5.34
(display (compile
          '(define (factorial n)
             (define (iter product counter)
               (if (> counter n)
                   product
                   (iter (* counter product)
                         (+ counter 1))))
             (iter 1 1))
          'val
          'next))


(set! label-counter 0)
(newline)
(newline)


;; compilation result of the iterative factorial definition

(define compiled-factorial-iter
  '(
    ; compile factorial procedure and skip over code for the procedure body
    (assign val (op make-compiled-procedure) (label entry1) (reg env))
    (goto (label after-lambda2))
    
    ; compile procedure body of factorial
    entry1
    (assign env (op compiled-procedure-env) (reg proc))
    (assign env (op extend-environment) (const (n)) (reg argl) (reg env))
    ; compile iter procedure and skip over code for the procedure body
    (assign val (op make-compiled-procedure) (label entry3) (reg env))
    (goto (label after-lambda4))
    
    ; compile procedure body of iter
    entry3
    (assign env (op compiled-procedure-env) (reg proc))
    (assign env (op extend-environment) (const (product counter)) (reg argl) (reg env))
    
    ; begin actual procedure body
    (save continue)
    (save env)
    ; compute (> counter n)
    (assign proc (op lookup-variable-value) (const >) (reg env))
    (assign val (op lookup-variable-value) (const n) (reg env))
    
    (assign argl (op list) (reg val))
    (assign val (op lookup-variable-value) (const counter) (reg env))
    (assign argl (op cons) (reg val) (reg argl))
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch8))
    
    compiled-branch9
    (assign continue (label after-call10))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch8
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (> counter n)
    after-call10
    (restore env)
    (restore continue)
    (test (op false?) (reg val))
    (branch (label false-branch6))
    
    ; return prduct
    true-branch5
    (assign val (op lookup-variable-value) (const product) (reg env))
    (goto (reg continue))
    
    ; compute (iter (* counter product) (+ counter 1))
    false-branch6
    (assign proc (op lookup-variable-value) (const iter) (reg env))
    (save continue)
    (save proc)
    (save env)
    ; compute (+ counter 1)
    (assign proc (op lookup-variable-value) (const +) (reg env))
    (assign val (const 1))
    (assign argl (op list) (reg val))
    (assign val (op lookup-variable-value) (const counter) (reg env))
    (assign argl (op cons) (reg val) (reg argl))
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch14))
    
    compiled-branch15
    (assign continue (label after-call16))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch14
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (+ counter 1)
    after-call16
    (assign argl (op list) (reg val))
    (restore env)
    (save argl)
    ; compute (* counter product)
    (assign proc (op lookup-variable-value) (const *) (reg env))
    (assign val (op lookup-variable-value) (const product) (reg env))
    (assign argl (op list) (reg val))
    (assign val (op lookup-variable-value) (const counter) (reg env))
    (assign argl (op cons) (reg val) (reg argl))
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch11))
    
    compiled-branch12
    (assign continue (label after-call13))
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch11
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    
    ; val now contains result of (* counter product)
    after-call13
    (restore argl)
    (assign argl (op cons) (reg val) (reg argl))
    (restore proc)
    (restore continue)
    ; apply iter and return its value
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch17))
    
    ; this block makes the iterative factorial take constant stack space.
    ; In the recursive factorial, we have an additional instruction
    ; (assign continue (label after-call9)), which restores argl saved in
    ; false-branch4. 
    compiled-branch18
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch17
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    (goto (reg continue))
    
    after-call19
    after-if7
    after-lambda4
    
    ; assign the procedure to the variable iter
    (perform (op define-variable!) (const iter) (reg val) (reg env))
    (assign val (const ok))
    ; compute (iter 1 1)
    (assign proc (op lookup-variable-value) (const iter) (reg env))
    (assign val (const 1))
    (assign argl (op list) (reg val))
    (assign val (const 1))
    (assign argl (op cons) (reg val) (reg argl))
    (test (op primitive-procedure?) (reg proc))
    (branch (label primitive-branch20))
    
    compiled-branch21
    (assign val (op compiled-procedure-entry) (reg proc))
    (goto (reg val))
    
    primitive-branch20
    (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
    (goto (reg continue))
    
    ; val now contains the result of (iter 1 1)
    after-call22
    after-lambda2
    
    ; assign the procedure to the variable factorial
    (perform (op define-variable!) (const factorial) (reg val) (reg env))
    (assign val (const ok))
    ))




; ex 5.35
(define (f x)
  (+ x (g (+ x 2))))



; ex 5.36

; the compiler evaluates operands from right to left, this is because in
; construct-arglist, we've reversed operand codes, and then processed the
; list of compiled operand codes from left to right.
;
; to change the evaluation order, instead of reversing operand-codes in the
; first place, we evaluate them from left to right and reverse the arglist
; at the end. By doing this, the reversing is done at run time instead
; of compile time

(define (construct-arglist-left-to-right operand-codes)
  (if (null? operand-codes)
      (make-instruction-sequence
       '() '(argl)
       '((assign argl (const ()))))
      (let ((code-to-get-last-arg
             (append-instruction-sequences
              (car operand-codes)
              (make-instruction-sequence
               '(val) '(argl)
               '((assign argl (op list) (reg val)))))))
        (if (null? (cdr operand-codes))
            code-to-get-last-arg
            (append-instruction-sequences
             (preserving '(env)
                         code-to-get-last-arg
                         (code-to-get-rest-args (cdr operand-codes)))
             ;; reverse argl at the end
             (make-instruction-sequence
              '(argl) '(argl)
              '((assign argl (op reverse) (reg argl)))))))))