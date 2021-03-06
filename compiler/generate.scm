;; ***** BEGIN LICENSE BLOCK *****
;; Roadsend PHP Compiler
;; Copyright (C) 2007-2008 Roadsend, Inc.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
;; ***** END LICENSE BLOCK *****


;;;; Generate Scheme code from a PHP AST
(module generate
   (include "php-runtime.sch")
   (library php-runtime)
   (library profiler)
   (import (ast "ast.scm")
	   (declare "declare.scm") )
   (export
    (generic generate-code node)) )


;XXX these global variables will need to be unified with the
;runtime variables of interpreted code somehow

(define *current-block* 'unset)


;unlike in evaluate.scm, this just contains the names of the exit functions
(define *break-stack* '())

;and this the names of the continue functions
(define *continue-stack* '())

(define *constant-bindings* '())

;for parent static method invocations -- they don't know who their daddy is.
(define *current-parent-class-name* #f)

;for method-decl stack trace entries and magic constnats
(define *current-class-name* #f)
(define *current-function-name* #f)
(define *current-method-name* #f)

;collect the actual code for the functions
(define *functions* '())

;the name of the current environment for looking up variable variables
(define *current-var-var-env* #f)

(define *required-asts* '())
(define *exports* '())

(define *runtime-function-sigs* '())

(define *file-were-compiling* "")


;;;; generate-code
(define-generic (generate-code node)
   (cond
      ((list? node)
       (let ((node (filter (lambda (n) (not (nop? n))) node)))
	  (cons 'begin
		(map generate-code node))))
      ((eqv? node :next) :next)
      (else
       (error 'generate-code
              (with-output-to-string
                 (lambda ()
                    (print "generate-code: Don't know what to do with node: " node ", see?")))
              #t))))

(define (%generate-early-ast-class-declares ast-class-list)
   (let ((class-defs '()))
      (php-hash-for-each ast-class-list
			 (lambda (k declared-class)
			    (set! class-defs (cons (generate-class-decl declared-class) class-defs))))
      (reverse class-defs)))

(define-method (generate-code node::php-ast)
   (set! *functions* '())
   (set! *constant-bindings* '())
   (set! *exports* '())
   (set! *runtime-function-sigs* '())
   (set! *current-ast* node)
   
   (dynamically-bind (*current-block* node)
      (dynamically-bind (*current-var-var-env* '*current-variable-environment*) ;'*global-env*)
	 ;;use *file-were-compiling* instead of the locations in the ast
	 ;;because it's been canonicalized some by driver.scm
	 (dynamically-bind (*file-were-compiling*
                            ;(php-ast-real-filename node)
                            (php-ast-project-relative-filename node))
	   (let ((class-defs (%generate-early-ast-class-declares (php-ast/gen-class-decl-list node)))
		 (global-code (cdr ;strip off the 'begin
			       ;remove the nops from function decls et al.
			       (filter (lambda (a) (not (nop? a)))
				       (generate-code (php-ast-nodes node))))))
	       (values
		(fixup-onums
		 (cons
		  ;the function containing the global code
		  `(lambda (argv)
		      
		      (set! *PHP-FILE* ,*file-were-compiling*)
		      
		      
		      ,@(profile-wrap (string->symbol *file-were-compiling*)
                                      ;; it's okay to omit the return function because we don't have to worry
                                      ;; about returns that aren't in this AST -- return from an included file
                                      ;; just returns from the include().
				      `(,(bind-exit-if (php-ast/gen-needs-return? node) 'return
                                            `(let ,(global-bindings)
                                                #t ;so it's never empty
						;
						; this is the list of classes we are able to declare early, meaning
						; they had no parent or their parent was defined in this module
						;
						,@class-defs
						(unless (try-import-cached-sigs ,(php-ast-real-filename node))
						   ,@*runtime-function-sigs*)
                                                ,@global-code)))) )
		  ;the other functions (class definition is in here too, and is dependent on order)
		  (reverse *functions*)))
		*required-asts*
		*exports*))))))

(define (fixup-onums code)
   "For each onum found, replace it with a symbol bound to an appropriate
onum.  Append the bindings for the new symbols and code."
   (letrec ((onums '())
	    (onum-replace
	     (lambda (code)
		(if (php-number? code)
		    (cond
;; Now that integer onums are bigloo elongs, we use the elong notation
;; for them.  This has the advantage that we can put them in constant
;; contexts like quoted lists. --timjr 2006.5.6
;; 		       ((and (onum-long? code) (= 0 (onum-compare code *zero*)))
;; 			'*zero*)
;; 		       ((and (onum-long? code) (= 0 (onum-compare code *one*)))
;; 			'*one*)
                       ((onum-long? code) code)
		       (else
			(let ((the-num (gensym 'num)))
			   (pushf `(define ,the-num
				      ,(if (onum-long? code)
					   (onum->elong code)
					   (onum->float code)))
				  onums)
			   the-num)))
		    (if (pair? code)
			(cons (onum-replace (car code))
			      (onum-replace (cdr code)))
			code)))))
      (let ((new-code (onum-replace code)))
	 ;the car of the code is treated specially by driver.scm -- the global function
	 ;the constants have to be placed before their uses in the case of
	 ;e.g. static variables in php functions.
	 (cons (car new-code) (append onums (cdr new-code))))))

(define (generate-function-invoke-common node::function-invoke/gen)
   (with-access::function-invoke/gen node (location name arglist return-used? dastardly?)   
      (if (ast-node? name)
	  `(php-funcall ,(get-value name)
			,@(map get-location arglist))
	  (let* ((canonical-name (function-name-canonicalize name))
		 (sig (or (get-php-function-sig canonical-name)
			  (get-library-include canonical-name #f)))
		 (arglist-len (length arglist)))
	     (if sig
		 (try
		  (begin
		     (php-compiletime-check-arity sig name arglist-len (lambda (msg) (warning/loc node msg)))
		     (let ((function-ast (hashtable-get *function->ast-table* canonical-name)))
			(when function-ast
			   (pushf function-ast *required-asts*)))
		     `(,@(if (function-available-at-link-time? sig)
			     `(,canonical-name)
			     `(php-funcall ',canonical-name))
			 ,@(let ((total-args (if (sig-var-arity? sig)
						 arglist-len
						 (sig-length sig))))
			      (let loop ((i 0)
					 (args '()))
				 (if (< i total-args)
				     (loop (+ i 1)
					   (cons (pass-argument (if (< i arglist-len)
								    (list-ref arglist i)
								    #f)
								(sig-ref sig i))
						 args))
				     (reverse args))))))
		  (lambda (e p m o)
		     (php-error/loc node m)
		     (e #t)))
		 (begin
		    `(php-funcall ',name
				  ,@(map get-location arglist))))))))

(define-method (generate-code node::function-invoke/gen)
    (with-access::function-invoke/gen node (location name arglist return-used? dastardly?)
       `(begin
	   ;;The *PHP-FILE* sets around function-invoke have to be there,
	   ;;because *PHP-FILE* is used to resolve include file paths, and
	   ;;function-invoke generates the code for include() and friends.
	   ;;(They're builtins).
	   (set! *PHP-FILE* ,*file-were-compiling*)
	   (set! *PHP-LINE* ,(car location))
	   ,(if return-used?
		(let ((retval (gensym 'retval)))
		   `(let ((,retval ,(generate-function-invoke-common node)))
		       (set! *PHP-FILE* ,*file-were-compiling*)
		       (set! *PHP-LINE* ,(car location))
		       ,@(if (and dastardly? (not (global-scope?)))
			     (refresh-local-variables) '())
		       ,retval))
		`(begin
		    ,(generate-function-invoke-common node)
		    (set! *PHP-FILE* ,*file-were-compiling*)
		    (set! *PHP-LINE* ,(car location))
		    ,@(if (and dastardly? (not (global-scope?)))
			  (refresh-local-variables) '()))))))

(define (refresh-local-variables)
   ;; update the value of variables from the variable env
   ;; this should work to a first approximation, anyway...
   (let ((c '()))
      (hashtable-for-each (current-symtab)
	 (lambda (name type)
	    (pushf `(set! ,name (env-lookup ,*current-var-var-env* ,(undollar name))) c)))
      c))

(define-method (generate-code node::nop)
   '(begin ) )

;;We need to force the hashtable to be copied, so set this to true if
;;you're looking up for the purpose of mutating something contained
;;in the hashtable.  Otherwise the hashtable's contents will be changed
;;without any pending copies being forced through.
(define *hash-lookup-writable* #f)

(define-method (generate-code node::hash-lookup)
   (with-access::hash-lookup node (hash key)
      (let* ((the-key (get-value key))
             (pre (precalculate-string-hashnumber the-key)))
         (if pre
             ;; precalculated hashnumber
             (if *hash-lookup-writable*
                 (if (is-hash? hash)
                     `(php-hash-lookup/pre ,(get-value hash) ,the-key ,pre)
                     `(%general-lookup/pre ,(get-value hash) ,the-key ,pre))
                 (if (is-hash? hash)
                     `(php-hash-lookup-honestly-just-for-reading/pre ,(get-value hash) ,the-key ,pre)
                     `(%general-lookup-honestly-just-for-reading/pre ,(get-value hash) ,the-key ,pre)))
             ;; no precalculated hashnumber
             (if *hash-lookup-writable*
                 (if (is-hash? hash)
                     `(php-hash-lookup ,(get-value hash) ,the-key)
                     `(%general-lookup ,(get-value hash) ,the-key))
                 (if (is-hash? hash)
                     `(php-hash-lookup-honestly-just-for-reading ,(get-value hash) ,the-key)
                     `(%general-lookup-honestly-just-for-reading ,(get-value hash) ,the-key)))))))


(define-method (generate-code node::literal-array)
   (with-access::literal-array node (array-contents)
      (let ((new-hash (gensym 'newhash)))
         `(let ((,new-hash (make-php-hash)))
             ,@(map
                (lambda (a)
                   (with-access::array-entry a (key value ref?)
                      (let* ((key (get-value key))
                             (pre (precalculate-string-hashnumber key)))
                         (if pre
                             `(php-hash-insert!/pre ,new-hash
                                                    ,key
                                                    ,pre
                                                    ,(if ref?
                                                         (get-location value)
                                                         (get-value value)))
                             `(php-hash-insert! ,new-hash
                                                ,key
                                                ,(if ref?
                                                     (get-location value)
                                                     (get-value value)))))))
                array-contents)
             ,new-hash))))

(define-method (generate-code node::postcrement)
   (with-access::postcrement node (crement lval)
      (let ((old (gensym 'old)))
	 `(let ((,old ,(get-value lval)))
	     ,(update-value lval
			    (if (is-numeric? lval)
				(ecase crement
				   ((--) `(--/num ,old))
				   ((++) `(++/num ,old)))
				(ecase crement
				   ((--) `(-- ,old))
				   ((++) `(++ ,old)))))
	     ,old))))


(define-method (generate-code node::precrement)
   (with-access::precrement node (crement lval)
      (update-value lval
		    (if (is-numeric? lval)
			(ecase crement
			    ((--) `(--/num ,(get-value lval)))
			    ((++) `(++/num ,(get-value lval))))
			(ecase crement
			   ((--) `(-- ,(get-value lval)))
			   ((++) `(++ ,(get-value lval))))))))



(define-method (generate-code node::arithmetic-unop)
   (with-access::arithmetic-unop node (op a)
      (let ((a-val (get-value a)))
         (cond
            ((compile-time-constant? a-val)
             (ecase op
                ((php-+) a-val)
                ((php--) (php-- *zero* a-val))))
            ((is-numeric? a)
             (ecase op
                ((php-+) `,a-val)
                ((php--) `(php--/num *zero* ,a-val))))
            (else
             (ecase op
                ((php-+) `,a-val)
                ((php--) `(php-- *zero* ,a-val))))))))


(define-method (generate-code node::assigning-arithmetic-op)
   (with-access::assigning-arithmetic-op node (op lval rval)
      (let ((a (get-value lval))
	    (b (get-value rval)))
	 (update-value lval
		       (if (and (is-numeric? lval)
				(is-numeric? rval))
			   (ecase op
			      ((php-+) `(php-+/num ,a ,b))
			      ((php--) `(php--/num ,a ,b))
			      ((php-*) `(php-*-/num ,a ,b))
			      ((php-/) `(php-//num ,a ,b))
			      ((php-%) `(php-% ,a ,b)) ;xxx zoot!
			      ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
			      ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
			      ((bitwise-not) `(bitwise-not ,b))
			      ((bitwise-or) `(bitwise-or ,a ,b))
			      ((bitwise-xor) `(bitwise-xor ,a ,b))
			      ((bitwise-and) `(bitwise-and ,a ,b)))
			   (ecase op
			      ((php-+) `(php-+ ,a ,b))
			      ((php--) `(php-- ,a ,b))
			      ((php-*) `(php-* ,a ,b))
			      ((php-/) `(php-/ ,a ,b))
			      ((php-%) `(php-% ,a ,b))
			      ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
			      ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
			      ((bitwise-not) `(bitwise-not ,b))
			      ((bitwise-or) `(bitwise-or ,a ,b))
			      ((bitwise-xor) `(bitwise-xor ,a ,b))
			      ((bitwise-and) `(bitwise-and ,a ,b)))) ))))


(define-method (generate-code node::assigning-string-cat)
   (with-access::assigning-string-cat/gen node (lval rval lhs-is-output-port?)
      (if lhs-is-output-port?
	  (begin
	     ;this is just to make sure that the lval gets bound, in case
	     ;it's only used here
	     (generate-code lval)
	     `(display (mkstr ,@(strip-mkstr (get-value rval)))
		       ,(string-port-name (var-name lval))))
	  (update-value lval `(mkstr ,@(strip-mkstr (get-value lval))
				     ,@(strip-mkstr (get-value rval)))))))

(define-method (generate-code node::foreach-loop)
   (with-access::foreach-loop/gen node (array key value body string-ports needs-break? needs-continue?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue))
	    (arrayname (gensym 'array))
	    (started? (gensym 'started?)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let ((,arrayname ,(get-value array))
			  (,started? #f))
                       (set! ,arrayname
                             (copy-php-data
                              (if (and (php-object? ,arrayname) (not (php-object-instanceof ,arrayname "Traversable")))
                                  (convert-to-hash ,arrayname)
				  ; Iterator will pass through
                                  ,arrayname)))
		       ; handle IteratorAggregate
		       (when (and (php-object? ,arrayname) (php-object-instanceof ,arrayname "IteratorAggregate"))
			  (set! ,arrayname (container-value (call-php-method-0 ,arrayname "getIterator")))
			  (unless (and (php-object? ,arrayname)
				       (php-object-instanceof ,arrayname "Iterator"))
			     (php-throw-builtin-exception "Object returned from getIterator() must implement interface Iterator")
			     (set! ,arrayname #f)))
		       (if (not (or (php-hash? ,arrayname) (php-object? ,arrayname)))
			   (php-warning "Not an array or iterable object in foreach, variable is " (get-php-datatype ,arrayname))
			   (begin
			      (if (php-object? ,arrayname)
				  (call-php-method-0 ,arrayname "rewind")
				  (php-hash-reset ,arrayname))
			      ; this bloats the generation a bit but avoids conditionals in the inner loop
			      ; perhaps we could optimize it with some type inference
			      (if (php-object? ,arrayname)
				  ; object
				  (let loop ()
				     (if ,started?
					 (call-php-method-0 ,arrayname "next")
					 (set! ,started? #t))
				     (when (convert-to-boolean (call-php-method-0 ,arrayname "valid"))
					,(update-value value `(copy-php-data (call-php-method-0 ,arrayname "current")))
					,(unless (null? key)
					    (update-value key `(call-php-method-0 ,arrayname "key")))
					,(bind-exit-if needs-continue? continuename
						       (generate-code body))
					(loop)))
				  ; hash
				  (let loop ()
				     (if ,started?
					 (php-hash-advance ,arrayname)
					 (set! ,started? #t))
				     (when (php-hash-has-current? ,arrayname)
					,(update-value value `(copy-php-data (php-hash-current-value ,arrayname)))
					,(unless (null? key)
					    (update-value key `(php-hash-current-key ,arrayname)))
					,(bind-exit-if needs-continue? continuename
						       (generate-code body))
					(loop))))
			      ;
			      ))))))))))



(define (string-port-name name)
   (symbol-append name '-port))

(define-method (generate-code node::while-loop)
   (with-access::while-loop/gen node (body condition string-ports needs-break? needs-continue?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let loop ()
		       (when ,@(if (null? condition)
				   '(#t)
				   `(,(get-boolean condition)))
			     ,(bind-exit-if needs-continue? continuename
				 (generate-code body))
			     (loop))))))))))



(define-method (generate-code node::for-loop)
   (with-access::for-loop/gen node (init condition step body string-ports needs-continue? needs-break?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue))
	    (started? (gensym 'started?)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(begin
		       ,@(if (null? init)
			     '()
			     (list (generate-code init)))
		       (let ((,started? #f))
			  (let loop ()
			     
			     ;this is to make sure that the step is executed even if the user does a continue
			     ;and so that we only save the loop once
			     (if ,started?
				 ,@(if (null? step)
				       '()
				       (list (generate-code step)))
				 (begin
				    ;			    (set! *current-loop-continue* loop)
				    (set! ,started? #t)))
			     (when ,(if (null? condition)
					#t
					`(begin ,@(map get-boolean condition)))    ;(convert-to-boolean ,(generate-code condition))))
				(begin
				   ,@(if (null? body)
					 '()
					 (list
					  (bind-exit-if needs-continue? continuename
					     (generate-code body))))
				   (loop)))))))))))))

(define (bind-string-ports string-ports form)
   (if (null? string-ports)
       form
       ;bind the string ports
       `(let ,(map (lambda (name)
		      `(,(string-port-name name) (open-output-string)))
		   string-ports)
	   ;generate code to copy the previous value of the string that's being replaced
	   ;into its port
	   ,@(map (lambda (name)
		     `(display (mkstr ,name) ,(string-port-name name)))
		  string-ports)
	   (unwind-protect
	      ,form
	      ;generate code to copy strings out of the string-ports after the form
	      ,@(map (lambda (name)
			;; since atm only a var can be string-port-replaced, we can avoid
			;; the generalized update-value.  also, string-port-replacement
			;; only happens in code that gets type analyzed (atm), so we can use
			;; the symbol table to check for containerness.
			(if (types-eqv? (hashtable-get (current-symtab) name) 'container)
			    `(container-value-set! ,name (close-output-port ,(string-port-name name)))
			    `(set! ,name (close-output-port ,(string-port-name name)))))
		     string-ports)))))


(define-method (generate-code node::break-stmt)
   (with-access::break-stmt node (level)
      ;;unfortunately, in the general case, the continue and break stacks
      ;;must be reified.  see bug 2385
      (let ((the-level (if (null? level) 0 (generate-code level)))
	    (level (gensym 'level))
	    (break-stack (gensym 'break-stack)))
	 `(let ((,level (max 0 (- (mkfixnum ,the-level) 1)))
		(,break-stack (list ,@*break-stack*)))
	     (if (>= ,level (length ,break-stack))
		 (php-error (format "Cannot break ~A level~A"
				    (+ ,level 1) (if (> ,level 0) "s" "")))
		 ((list-ref ,break-stack ,level) #t))))))

(define-method (generate-code node::continue-stmt)
   (with-access::continue-stmt node (level)
      (let ((the-level (if (null? level) 0 (generate-code level)))
	    (level (gensym 'level))
	    (continue-stack (gensym 'continue-stack)))
	 `(let ((,level (max 0 (- (mkfixnum ,the-level) 1)))
		(,continue-stack (list ,@*continue-stack*)))
	     (if (>= ,level (length ,continue-stack))
		 (php-error (format "Cannot continue ~A level~A"
				    (+ ,level 1) (if (> ,level 0) "s" "")))
		 ((list-ref ,continue-stack ,level) #t))))))

(define-method (generate-code node::return-stmt/gen)
   (with-access::return-stmt/gen node (value cont?)
      (if cont?
	  `(return (container->reference! ,(get-location value)))
          (if (method-decl? *current-block*)
              ;; I've changed it so that methods always return
              ;; containers, because container-value is so much
              ;; cheaper than maybe-unbox.  It would be better, of
              ;; course, to skip the boxing and unboxing in cases
              ;; where it's not necessary.  --timjr 2006.5.15a
              `(return (make-container ,(get-copy value)))
              `(return ,(get-copy value))))))

(define-method (generate-code node::exit-stmt)
   (with-access::exit-stmt node (rval)
      `(php-funcall 'php-exit ,@(if (null? rval)
				    '()
				    (list (get-value rval))))))


(define-method (generate-code node::if-stmt)
   (with-access::if-stmt node (condition then else)
      `(if ,(get-boolean condition)
	   ,(generate-code then)
	   ,(generate-code else))))

(define-method (generate-code node::throw)
   (with-access::throw node (rval)
      `(let ((except-obj ,(generate-code rval)))
	  (if (php-object? (maybe-unbox except-obj))
	      (if (php-object-is-a (maybe-unbox except-obj) "Exception")
		  (php-exception (maybe-box except-obj))
		  (php-error "thrown exceptions must be derived from Exception base class"))
	      (php-error "can only throw objects")))))

(define-method (generate-code node::try-catch)
   (with-access::try-catch node (try-body catches)
      ; extract class names we are catching for this try block
      (let ((catch-classname-list '())
	    (catch-block-list '())
	    (except-hash-entries '()))
	 (let loop ((clist catches))
	    (when (pair? clist)
	       (let ((current-catch (car clist))
		     (except-proc-name #f))
		  (with-access::catch current-catch (catch-class catch-var catch-body)
		     (set! except-proc-name (gensym 'catch))
		     (set! catch-classname-list (cons catch-class catch-classname-list))
		     (set! except-hash-entries (cons `(hashtable-put! except-proc-hash ,(mkstr catch-class) ,except-proc-name) except-hash-entries))
		     ; we have to generate code for each catch block, even if it may never run
		     ; because we won't know until runtime
		     ; we do this by defining a function for each catch block that we can run later, in case we
		     ; match that exception class
		     (set! catch-block-list (cons `(,except-proc-name
						    (lambda (e-var)
						       ,(update-location catch-var `e-var)
						       ,(generate-code catch-body)))
						  catch-block-list)))
		  (loop (cdr clist)))))
	 ;
	 ; generated code
	 ;
	 `(letrec (,@catch-block-list)
	     (let ((except-proc-hash (make-hashtable)))
		,@except-hash-entries
		(let ((try-result (bind-exit (except)
				     (push-try-stack ',catch-classname-list except)
				     ,(generate-code try-body)
				     (pop-try-stack))))
		   (when (pair? try-result)
		      (pop-try-stack) ; pop here because we exited before the pop in the try block
		      ; we excepted: run the correct catch block
		      (let ((except-proc (mkstr (car try-result)))
			    (except-obj (cdr try-result)))
			 ((hashtable-get except-proc-hash except-proc) except-obj)
			 ))))))))


(define-method (generate-code node::lyteral)
   (lyteral-value node))

(define-method (generate-code node::literal-integer)
   (convert-to-number (lyteral-value node)))


(define-method (generate-code node::literal-float)
   (convert-to-number (lyteral-value node)))

(define-method (generate-code node::literal-string)
   (mkstr (lyteral-value node)))

(define-method (generate-code node::literal-null)
   ''())

(define-method (generate-code node::typecast)
   (with-access::typecast node (typecast rval)
      ;      (print "rval is: " rval ", get-value is " (get-value rval))
      (ecase typecast
	 ((boolean) (get-boolean rval))
	 ((object) `(convert-to-object ,(get-value rval)))	 
	 ((integer) `(convert-to-integer ,(get-value rval)))
	 ((float) `(convert-to-float ,(get-value rval)))
	 ((string) `(convert-to-string ,(get-value rval)))
	 ((hash) `(convert-to-hash ,(get-value rval))))))

(define-method (generate-code node::arithmetic-op)
   (with-access::arithmetic-op node (op a b)
      (let ((a-val (get-value a))
	    (b-val (get-value b)))
	 
	 (cond
	    ((and (compile-time-constant? a-val)
		  (compile-time-constant? b-val))
	     (ecase op
		((php--) (php-- a-val b-val))
		((php-+) (php-+ a-val b-val))
		((php-/) (php-/ a-val b-val))
		((php-*) (php-* a-val b-val))
		((php-%) (php-% a-val b-val))))
	    ((and (is-numeric? a)
		  (is-numeric? b))
	     (ecase op
		((php--) `(php--/num ,a-val ,b-val))
		((php-+) `(php-+/num ,a-val ,b-val))
		((php-/) `(php-//num ,a-val ,b-val))
		((php-*) `(php-*-/num ,a-val ,b-val))
		((php-%) `(php-% ,a-val ,b-val))) ) ;xxx zoot!
	    (else
	     (ecase op
		((php--) `(php-- ,a-val ,b-val))
		((php-+) `(php-+ ,a-val ,b-val))
		((php-/) `(php-/ ,a-val ,b-val))
		((php-*) `(php-* ,a-val ,b-val))
		((php-%) `(php-% ,a-val ,b-val))) )))))


(define-method (generate-code node::echo-stmt)
   (with-access::echo-stmt node (stuff)
      (if (list? stuff)
	  (if (> (length stuff) 1)
	      `(begin 
		  ,@(map (lambda (c)
			    `(echo ,(get-value c)))
			 stuff))
	      `(echo ,(get-value (car stuff))))
	  `(echo ,(get-value stuff)))))


(define-method (generate-code node::static-decl)
;   (print "generating-code node: " node  ", current-block " *current-block*)
   (with-access::static-decl node (var)
      (if (or (not (current-static-vars))
		  (hashtable-get (current-static-vars) var))
	  ''static-decl
	  (error 'generate-code-static-decl
		 "somehow this static-decl didn't get declared" node) )))

(define-method (generate-code node::global-decl)
   (with-access::global-decl node (var)
      (if (ast-node? var)
	  (let ((val (get-value var)))
	     ;; In this case, a var-var decl, you can only access the var
	     ;; with $$, not directly, because we don't know its name at
	     ;; compile time.
	     (unless (global-scope?)
		`(env-extend ,*current-var-var-env*
			     (mkstr ,val)
			     (env-lookup *global-env* (mkstr ,val)))))
	  (begin
	     (add-binding-to-current-block var '(make-container '()))
	     (unless (global-scope?)
		`(begin
		    (set! ,var (env-lookup *global-env* ,(undollar var)))
		    (when ,*current-var-var-env*
		       (env-extend ,*current-var-var-env* ,(undollar var) ,var))))))))

(define-method (generate-code node::var)
   (with-access::var/gen node (name cont?)
      (if cont?
	  (add-binding-to-current-block name '(make-container '()))
	  (add-binding-to-current-block name ''()))
      (if (global-scope?)
	  ;; xxx should put an assert here
	  `(env-internal-index-value ,name)
	  name)))

(define-method (generate-code node::var-var)
   (with-access::var-var node (lval)
      (flag-needs-var-var-env!)
     `(env-lookup ,*current-var-var-env* (mkstr ,(get-value lval)))))

(define-method (generate-code node::assignment)
   (with-access::assignment/gen node (lval rval lhs-is-output-port?)
      (if lhs-is-output-port?
	  (begin
	     ;this is just to add the lval to the symtab so it gets bound
	     ;in case it's not used anyplace other than here
	     (generate-code lval)
	     ;assume the rval is of the form (mkstr lval ...) and strip lval off it
	     `(display ,(cons 'mkstr (cddr (generate-code rval)))
		       ,(string-port-name (var-name lval))))
	  (update-value lval (get-copy rval)))))

(define-method (generate-code node::disable-errors)
   (with-access::disable-errors node (body)
      `(begin
	  (dynamically-bind (*errors-disabled* #t)
	     ,(generate-code body) ))))


(define-method (generate-code node::list-assignment)
   (with-access::list-assignment node (lvals rval)
      (let ((rval-name (gensym 'rval)))
	 `(let ((,rval-name ,(get-value rval)))
	     (if (convert-to-boolean ,rval-name)
		 (begin
		    ,@(remq '()
			    (map (let ((i (length lvals)))
				    (lambda (var)
				       (set! i (- i 1))
				       (if (null? var)
					   '()
					   ;XXX copy?
					   (update-value var `(php-hash-lookup ,rval-name ,i)))))
				 (reverse lvals)))
		    ,rval-name)
		 ; if rval is empty, set vars in list to NULL
		 (begin
		    ,@(remq '()
			    (map (lambda (var)
				    (if (null? var)
					'()
					;XXX copy?
					(update-value var `'())))
				 (reverse lvals)))
		    #f))))))

(define-method (generate-code node::reference-assignment)
   (with-access::reference-assignment node (lval rval)
      (if (or (function-invoke? rval)
              (method-invoke? rval)
              (constructor-invoke? rval)
              (static-method-invoke? rval)
              (parent-method-invoke? rval))
          ;; maybe emit a strict warning?
          (let ((rvalname (gensym 'rval)))
             `(let ((,rvalname ,(get-location rval)))
                 (if (container-reference? ,rvalname)
                     ,(update-location lval rvalname)
                     ,(update-value lval `(container-value ,rvalname)))))
          (update-location lval `(container->reference!
                                  ,(get-location rval))))))

(define-method (generate-code node::unset-stmt)
   (with-access::unset-stmt node (lvals)
      `(begin ,@(map unset lvals))))

(define-method (generate-code node::isset-stmt)
   (with-access::isset-stmt node (rvals)
      (if (>fx (length rvals) 1)
	  `(and ,@(map isset rvals))
	  (isset (car rvals)))))

(define-method (generate-code node::empty-stmt)
   (with-access::empty-stmt node (rval)
      (if (hash-lookup? rval)
	  ; arrayaccess hook
	  `(if ,(isset rval)
	      (php-empty? ,(get-value rval))
	      #t)
	  ; normal
	  `(php-empty? ,(get-value rval)))))

(define-method (generate-code node::switch-stmt)
   (with-access::switch-stmt/gen node (rval cases needs-continue? needs-break?)
      (if (null? cases)
	  ;;warn, evaluate just for side-effect
	  (begin
	     (warning/loc node "empty switch statement.")
	     (get-value rval))
	  (let ((breakname (gensym 'break))
		(switchflag (gensym 'switchflag))
		(switchvar (gensym 'switchvar)))
	     (dynamically-bind (*break-stack* (cons breakname *break-stack*))
		(dynamically-bind (*continue-stack* (cons breakname *continue-stack*))
		   (bind-exit-if (or needs-continue? needs-break?) breakname
		      `(let ((,switchflag #f)
			     (,switchvar ,(get-value rval)))
			  ,@(map
			     (lambda (c)
				(if (default-switch-case? c)
				    (with-access::default-switch-case c (body)
				       `(begin
					   (set! ,switchflag #t)
					   ,(generate-code body)))
				    ;				`(unless ,switchflag ,(generate-code body)))
				    (with-access::switch-case c (val body)
				       `(when (or ,switchflag
						  (equalp ,switchvar ,(get-value val)))
					   (set! ,switchflag #t)
					   ,(generate-code body)))))
			     cases)))))))))
	 
(define-method (generate-code node::do-loop)
   (with-access::do-loop/gen node (condition body string-ports needs-continue? needs-break? )
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let loop ()
		       ,(bind-exit-if needs-continue? continuename
			   (generate-code body))
		       (when ,(if (null? condition)
				  #t
				  (get-boolean condition))
			  (loop))))))))))

   


(define-method (generate-code node::class-decl)
   (error 'generate-code-class-decl "somehow this class didn't get declared" node))

(define-method (generate-code node::class-decl/gen)
   ; classes whose parents existed (in this module) at compile time should already be declared
   ; this is for e.g. classes whose base classes exist in another module
   (if (class-decl/gen-rendered? node)
       `'()
       (generate-class-decl node)))

(define (generate-class-decl node)
   (with-access::class-decl/gen node (name canonical-name parent-list implements flags properties static-properties class-constants methods rendered?)
      (if rendered?
	  `(begin 'class-already-rendered ',name)
	  (begin
	     (set! rendered? #t)
	     (let ((code '()))
		(if (member 'pcc-builtin flags)
		    (pushf `(define-builtin-php-class ',name ',parent-list ',implements ',flags) code)
		    (pushf `(define-php-class ',name ',parent-list ',implements ',flags) code))
		(dynamically-bind (*current-parent-class-name* (if (null? parent-list) '() (car parent-list)))
		   (dynamically-bind (*current-class-name* name)
                     (php-hash-for-each class-constants
                         (lambda (const-name const-val)
			    (pushf `(define-class-constant ',name ,const-name ,(get-value const-val))
				   code)))				     
		     (php-hash-for-each static-properties
		          (lambda (prop-name prop)
			     (pushf `(define-php-property ',name
					,prop-name
					,(if (null? (property-decl-value prop))
					     ''()
					     (get-value (property-decl-value prop)))
					',(property-decl-visibility prop)
					#t
					)
				    code)))
		     (php-hash-for-each properties
		         (lambda (prop-name prop)
			    (pushf `(define-php-property ',name
				 ,prop-name
				 ,(if (null? (property-decl-value prop))
				      ''()
				      (get-value (property-decl-value prop)))
				 ',(property-decl-visibility prop)
				 #f
				 )
			     code)))
		     (php-hash-for-each methods
			 (lambda (method-name method)
			    (with-access::method-decl method (location decl-arglist body ref? flags)
			     (dynamically-bind (*current-method-name* (mkstr name "::" method-name))
			      (dynamically-bind (*current-function-name* method-name)
			       (pushf `(define-php-method ',name
					  ',method-name
					  ',flags
					  ,(generate-code method))
				      code))))))))
		(pushf `(php-class-def-finalize ',name) code)
		(cons 'begin (reverse code)))))))


(define-method (generate-code node::constructor-invoke)
   (with-access::constructor-invoke node (location class-name arglist)       
      `(begin
	  (set! *PHP-FILE* ,*file-were-compiling*)
	  (set! *PHP-LINE* ,(car location))
	  (begin0
	   (let ((accessible (php-class-constructor-accessible
			      ,(if (ast-node? class-name)
				   (get-value class-name)
				   (mkstr class-name))
			      ',*current-class-name*)))
	      (when (pair? accessible)
		 (let ((vis (car accessible))
		       (constructor-name (cdr accessible)))
		    (php-error (format "Call to ~a ~a::~a() from invalid context"
				       vis
				       ,(if (ast-node? class-name)
					    (get-value class-name)
					    (mkstr class-name))
				       constructor-name))))
	      (construct-php-object ,(if (ast-node? class-name)
					 (get-value class-name)
					 (mkstr class-name))
				    ,@(map get-location arglist)))
	   (set! *PHP-FILE* ,*file-were-compiling*)
	   (set! *PHP-LINE* ,(car location))))))


(define-method (generate-code node::method-invoke)
   (with-access::method-invoke node (location method arglist)
      (with-access::property-fetch method (obj prop)
	 (let ((tramp (case (length arglist)
			 ((0) 'call-php-method-0)
			 ((1) 'call-php-method-1)
			 ((2) 'call-php-method-2)
			 ((3) 'call-php-method-3)
			 (else 'call-php-method)) ))
	    `(begin
		(set! *PHP-FILE* ,*file-were-compiling*)
		(set! *PHP-LINE* ,(car location))
		(let* ((obj-val ,(dynamically-bind (*hash-lookup-writable* #t)
						   (get-value obj)))
		       (prop-val ,(if (ast-node? prop)
				      (get-value prop)
				      (undollar prop)))
		       (accessible (php-method-accessible obj-val prop-val ',*current-class-name*))) ;,(if *current-class-name*
										;`(if (eqv? this-unboxed obj-val)
										;     ',*current-class-name*
										;     #f)
										;#f))))
		   (when (pair? accessible)
		      (let ((vis (car accessible))
			    (origin-class (cdr accessible)))
			 (php-error (format "Call to ~a method ~a::~a() from context '~a'"
					    vis
					    origin-class
					    prop-val
					    ',(if *current-class-name* *current-class-name* "")))))
		   (begin0
		    (,tramp obj-val
			    prop-val
			    ,@(map get-location arglist))
		    (set! *PHP-FILE* ,*file-were-compiling*)
		    (set! *PHP-LINE* ,(car location)) )))))))


(define-method (generate-code node::static-method-invoke)
    (with-access::static-method-invoke node (location class-name method arglist)
       (let ((class-canon (cond ((eqv? class-name '%self) *current-class-name*)
				(else class-name))))
	  (if (and (eqv? class-name '%self)
		   (eqv? class-canon #f))
	      (delayed-error/loc node "Cannot access self:: when no class scope is active")       
	      `(begin
		  (set! *PHP-FILE* ,*file-were-compiling*)
		  (set! *PHP-LINE* ,(car location))

		  (let* ((method-val ,(get-value method))
			 (accessible (php-method-accessible ',class-canon method-val
							     ,(if *current-class-name*
								  `*current-class-name*
								  `#f))))
		     (when (pair? accessible)
			(let ((vis (car accessible))
			      (origin-class (cdr accessible)))
			   (php-error (format "Call to ~a method ~a::~a() from context '~a'"
					      vis
					      origin-class
					      method-val
					      ',(if *current-class-name* *current-class-name* "")))))
		     
		     (begin0
		      ,(if (and *current-class-name*
				(compile-time-subclass? *current-class-name* class-name))
			   `(call-static-php-method ',class-canon this-unboxed method-val
						    ,@(map get-location arglist))
			   `(call-static-php-method ',class-canon NULL method-val
						    ,@(map get-location arglist)))
		      (set! *PHP-FILE* ,*file-were-compiling*)
		      (set! *PHP-LINE* ,(car location)) )))))))
       
(define-method (generate-code node::parent-method-invoke)
   (with-access::parent-method-invoke node (location name arglist)
      (if *current-parent-class-name*
	  `(begin
	      (set! *PHP-FILE* ,*file-were-compiling*)
	      (set! *PHP-LINE* ,(car location))
	      ;
	      ; XXX visibility check
	      ;
	      (begin0
	       (call-php-parent-method ',*current-parent-class-name*
				       this-unboxed
				       ,(get-value name)
				       ,@(map get-location arglist))
	       (set! *PHP-FILE* ,*file-were-compiling*)
	       (set! *PHP-LINE* ,(car location)) ))
	  (delayed-error/loc node
			     (format "generate-code-parent-method-invoke: no parent class to be found ~a"
				     node)))))

(define (generate-get-prop-access-type the-object the-property)
   `(php-object-property-visibility ,the-object
				    ,the-property
				    ,(if *current-class-name*
					 `this-unboxed
					 `#f)))

(define (generate-get-static-prop-access-type the-class the-property)
   (let ((context (if *current-class-name*
		      `*current-class-name*
		      #f)))
      `(php-class-static-property-visibility ',the-class
					     ,the-property
					     ,context)))

(define (generate-prop-visibility-check the-object the-property)
   `(when (pair? access-type)
       (let ((vis (car access-type)))
	  (php-error (format "Cannot access ~a property ~a::$~a" vis (php-object-class ,the-object) ,the-property)))))

(define (generate-static-prop-visibility-check the-class the-property)
   `(when (pair? access-type)
       (let ((vis (car access-type)))
	  (php-error (format "Cannot access ~a static property ~a::$~a" vis ,(mkstr the-class) ,the-property)))))

(define-method (generate-code node::property-fetch)
   (with-access::property-fetch node (location obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc node "property name is not a string, but should be."))
	 `(let* ((obj-evald ,the-object)
		 (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	     ; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
	     (set! *PHP-FILE* ,*file-were-compiling*)
	     (set! *PHP-LINE* ,(car location))	     
	     ,(generate-prop-visibility-check 'obj-evald the-property)
	     ,(if *hash-lookup-writable*
		  (if property-is-constant?
		      `(php-object-property/string
			obj-evald ,(mkstr the-property) access-type)
		      `(php-object-property obj-evald ,the-property access-type))
		  (if property-is-constant?
		      `(php-object-property-h-j-f-r/string
			obj-evald ,(mkstr the-property) access-type)
		      `(php-object-property-honestly-just-for-reading obj-evald ,the-property access-type)))))))

(define-method (generate-code node::static-property-fetch)
   (with-access::static-property-fetch node (location class prop)
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) *current-parent-class-name*)
			       (else class))))
	 (if (and (eqv? class '%self)
		  (eqv? class-canon #f))
	     (delayed-error/loc node "Cannot access self:: when no class scope is active")
	     (if (and (eqv? class '%parent)
		      (or (eqv? class-canon #f) (eqv? class-canon 'stdclass)))
		 (delayed-error/loc node "Cannot access parent:: when current class scope has no parent")
		 (let* ((the-property (if (var-var? prop)
					  (get-value prop)
					  prop))
			(prop-name (undollar (var-name the-property))))
		    `(let* ((prop-evald ,prop-name)
			    (access-type ,(generate-get-static-prop-access-type class-canon 'prop-evald)))
			; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
			(set! *PHP-FILE* ,*file-were-compiling*)
			(set! *PHP-LINE* ,(car location))
			,(generate-static-prop-visibility-check class-canon 'prop-evald)
			(php-class-static-property ',class-canon ,prop-name access-type))))))))

(define-method (generate-code node::class-constant-fetch)
   (with-access::class-constant-fetch node (class name)
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) *current-parent-class-name*)
			       (else class))))
	 (if (and (eqv? class '%self)
		  (eqv? class-canon #f))
	     (delayed-error/loc node "Cannot access self:: when no class scope is active")
	     (if (and (eqv? class '%parent)
		      (or (eqv? class-canon #f) (eqv? class-canon 'stdclass)))
		 (delayed-error/loc node "Cannot access parent:: when current class scope has no parent")
		 `(lookup-class-constant ',class-canon ,name))))))

(define-method (generate-code node::obj-clone)
   (with-access::obj-clone node (obj)
      `(let ((obj-val ,(get-value obj)))
	  (if (php-object? obj-val)
	      (clone-php-object obj-val)
	      (begin
		 (php-warning "clone on non object")
		 NULL)))))

(define-method (generate-code node::function-decl/gen)
   (with-access::function-decl/gen node
	 (location needs-env? name decl-arglist canonical-name container-table
		   variable-arity? toplevel? symbol-table static-vars body needs-return?)
      (let ((param-names (map formal-param-name decl-arglist)))
	 ;generate the code for the body, so we know if we need an env
	 (dynamically-bind (*current-function-name* name)
  	   (dynamically-bind (*current-block* node)
	    (dynamically-bind (*current-var-var-env* (if needs-env? 'env #f))
	       ;we generate the code for the body first, because in the process the
	       ;symbol-table is filled, so we know which variables to bind
	       (let* ((body-code (generate-code body))
		      (signature-code
		       `(begin
			   ,@(if (needs-alias? canonical-name)
				 `((store-alias ',canonical-name ',(autoalias canonical-name)))
				 '())
			   ,(runtime-sig location (autoalias canonical-name) toplevel? variable-arity? decl-arglist))))
		  (set! body-code
			(profile-wrap
			 name
			 (trace-wrap
			  'unset name param-names location
			  (shared-env-wrap
			   needs-env?
			   `(begin0
			     ,(bind-exit-if needs-return? 'return
                                 `(let ,(bindings symbol-table (append (hashtable-key-list static-vars) param-names))
                                     ,@(copy-and-type-non-reference-args decl-arglist)
                                     ,@(box-non-reference-container-args decl-arglist)
				     ,@(typehint-checks 'unset name decl-arglist)
                                     ,@(if variable-arity?
                                           `((push-func-args (cons* ,@param-names rest-args)))
                                           '())
                                     ,@(if needs-env?
                                           `(,@(add-arguments-to-env decl-arglist)
                                               ,@(add-bindings-to-env symbol-table)
                                               ,@(add-bindings-to-env static-vars)
                                               (set! *current-variable-environment* env))
                                           '())
                                     #t ;so it's never empty
                                     ,body-code
                                     NULL))
			     ,@(if variable-arity? `((pop-func-args)) '()))))))
		  (set! body-code
			`(lambda ,(let ((args param-names))
				(if variable-arity?
				    (if (null? args)
					'rest-args
					`(,@args . rest-args))
				    args))
			    ,(when (> (hashtable-size static-vars) 0)
				`(maybe-reset-my-statics))			    
			    ,@body-code))
		  (let ((static-bindings (bindings-generate static-vars container-table))
			(static-binding-resets (reset-bindings-generate static-vars container-table)))
		     (unless (null? static-bindings)
			(set! body-code `(let ,static-bindings
					    (letrec ((last-reset-serial 0)
						     (maybe-reset-my-statics
						      (lambda ()
							 (unless (=fx *runtime-reset-serial* last-reset-serial)
							    (set! last-reset-serial *runtime-reset-serial*)
							    ,@static-binding-resets))))
					    ,body-code)))))
		  (if toplevel? 
		      (begin
			 (pushf signature-code *runtime-function-sigs*)
			 (pushf `(define ,(autoalias canonical-name) ,body-code) *functions*)
			 (pushf (autoalias canonical-name) *exports*)
			 (make-nop '("in generate.scm" . "should be stripped")))
		      `(let ((,(autoalias canonical-name) ,body-code)) ,@(cdr signature-code))))))))))

(define-method (generate-code node::method-decl)
   (with-access::method-decl/gen node
	 (location name needs-env? decl-arglist canonical-name container-table
		   variable-arity? symbol-table static-vars body needs-return?)
      (if (eqv? body 'abstract-no-proc)
	  `'abstract-no-proc
	  ;generate the code for the body, so we know if we need an env
	  (dynamically-bind (*current-block* node)
	   (dynamically-bind (*current-var-var-env* (if needs-env? 'env #f))
	    (let* ((body-code (generate-code body))
		   (method-fun-name (string->symbol (mkstr *current-class-name* "=>" name)))
		   (required-params (filter required-formal-param? decl-arglist))
		   (optional-params (filter optional-formal-param? decl-arglist)))
	       
	       
	       (hashtable-remove! symbol-table '$this)
	       (set! body-code
		     `(define ,method-fun-name
			 (let ,(bindings-generate static-vars container-table)
			    (letrec ((last-reset-serial 0)
				     (maybe-reset-my-statics
				      (lambda ()
					 (unless (=fx *runtime-reset-serial* last-reset-serial)
					    (set! last-reset-serial *runtime-reset-serial*)
					    ,@(reset-bindings-generate static-vars container-table)))))
			    (lambda (this-unboxed ,@(map required-formal-param-name required-params)
					     . ;; ,(if (or variable-arity? (pair? optional-params)) 'optional-args '())
					     ;; unfortunately, the methods always need optional args, because we
					     ;; can't emit a compile-time error at the call site if the argument
					     ;; number is wrong, so we get a runtime arity error
                                             optional-args
                                             )
			       ,(when (> (hashtable-size static-vars) 0)
				   `(maybe-reset-my-statics))		       
			      ; this is needed for static calls and property fetches
			      (let ((*current-class-name* ',*current-class-name*))
			       ;unbox the non-reference args
			       ,@(map (lambda (p)
					 `(set! ,(formal-param-name p)
						(container-value ,(formal-param-name p))))
				      (filter (lambda (a)
						 (not (formal-param-ref? a)))
					      required-params))
			       ;bind the optional params to their default values
			       (let ,(map (lambda (p)
					     `(,(optional-formal-param-name p)
					       ,(let ((default (optional-formal-param-default-value p)))
						   (if (ast-node? default)
						       (get-value default)
						       default))))
					  optional-params)
				  ;override the default with the actual passed value, if it was passed
				  ,@(map (lambda (p)
					    `(when (pair? optional-args)
						(set! ,(optional-formal-param-name p)
						      ,(if (optional-formal-param-ref? p)
							   '(car optional-args)
							   '(container-value (car optional-args))))
						(set! optional-args (cdr optional-args))))
					 optional-params)
				  ,@(profile-wrap
				     (string->symbol (mkstr *current-class-name* "::" name))
				     (trace-wrap
				      (mkstr *current-class-name*)
				      name
				      (map formal-param-name decl-arglist) location
				      (shared-env-wrap
				       needs-env?
				       `(begin0
					 ,(bind-exit-if needs-return? 'return
                                             `(let ,(bindings symbol-table (append (hashtable-key-list static-vars)
                                                                                   (map formal-param-name decl-arglist)))
                                                 (let (($this ,(if (hashtable-get container-table '$this)
                                                                   `(make-container this-unboxed)
                                                                   'this-unboxed)))
                                                    ,@(copy-and-type-non-reference-args decl-arglist)
                                                    ,@(box-non-reference-container-args decl-arglist)
						    ,@(typehint-checks *current-class-name* name decl-arglist)
                                                    ,@(if variable-arity?
                                                          `((push-func-args
                                                             (cons* ,@(map required-formal-param-name required-params)
                                                                    optional-args)))
                                                          '())
                                                    ,@(if needs-env?
                                                          `(,@(add-arguments-to-env decl-arglist)
                                                              ,@(add-bindings-to-env symbol-table)
                                                              ,@(add-bindings-to-env static-vars)
                                                              (env-extend ,*current-var-var-env* "this" $this)
                                                              (set! *current-variable-environment* env))
                                                          '())
                                                    #t ;so it's never empty
                                                    ,body-code
                                                    ;; methods always box their return values.
                                                    (make-container NULL))))
					 ,@(if variable-arity? `((pop-func-args)) '()))))))))))))

	       (pushf body-code *functions*)
	       method-fun-name))))))



(define-method (generate-code node::function-decl)
   (error 'generate-code-function-decl "function decl didn't get declared" node))

(define-method (generate-code node::constant-decl)
   (with-access::constant-decl node (name value insensitive?)
      (let ((real-name (if (ast-node? name)
			   (get-value name)
			   (mkstr name))))
	 (if (null? insensitive?)
	     `(store-constant ,real-name ,(get-value value) #f)
	     `(store-constant ,real-name ,(get-value value)
			      (convert-to-boolean ,(get-value insensitive?)))))))

(define-method (generate-code node::php-constant)
   (with-access::php-constant node (name location)
      (let ((name (mkstr name)))
         ;;XXX Really, I don't want to be modifying this literal constant.
         ;;I'd rather have toplevel code like for the elongs.
         (cond ((string=? name "__LINE__")
		`(begin
		    ;; ensure that the line constant is up-to-date
		    (set! *PHP-LINE* ,(loc-line location))
		    (lookup-constant/smash '(,name))))
	       ((string=? name "__CLASS__")
		`,(mkstr *current-class-name*))
	       ((string=? name "__FUNCTION__")
		`,(mkstr *current-function-name*))
	       ((string=? name "__METHOD__")
		`,(mkstr *current-method-name*))
	       (else
		`(lookup-constant/smash '(,name)))))))

(define (strip-mkstr aval)
   ;this is so we can avoid nested mkstrs
   (if (and (pair? aval)
	    (eqv? 'mkstr (car aval)))
       (cdr aval)
       (list aval)))

(define-method (generate-code node::string-cat)
   (with-access::string-cat node (a b)
      (let ((a-val (get-value a))
	    (b-val (get-value b)))
	 (if (and (compile-time-constant? a-val)
		  (compile-time-constant? b-val))
	     (begin
		(mkstr a-val b-val))
	     `(mkstr ,@(strip-mkstr a-val)
		     ,@(strip-mkstr b-val))))))

(define-method (generate-code node::bitwise-op)
   (let ((a (get-value (bitwise-op-a node)))
	 (b (get-value (bitwise-op-b node)))
	 (op (bitwise-op-op node)))
      (ecase op
	 ((bitwise-or) `(bitwise-or ,a ,b))
	 ((bitwise-xor) `(bitwise-xor ,a ,b))
	 ((bitwise-and) `(bitwise-and ,a ,b))
	 ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
	 ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
	 (else (error 'generate-code-bitwise-op "don't know of operation" op)))))

(define-method (generate-code node::bitwise-not-op)
   `(bitwise-not ,(get-value (bitwise-not-op-a node))))

(define-method (generate-code node::comparator)
   (with-access::comparator node (op p q)
      (if (and (is-numeric? p) (is-numeric? q))
	  (let ((p (get-value p))
		(q (get-value q)))
	     (ecase op
		((identicalp equalp) `(equalp/num ,p ,q))
		((not-identical-p not-equal-p) `(not (equalp/num ,p ,q)))
		((less-than-p) `(less-than-p/num ,p ,q))
		((less-than-or-equal-p) `(less-than-or-equal-p/num ,p ,q))
		((greater-than-p) `(greater-than-p/num ,p ,q))
		((greater-than-or-equal-p) `(greater-than-or-equal-p/num ,p ,q))
		((instanceof) (delayed-error/loc node "instanceof expects an object instance"))))
	  (let ((p (get-value p))
		(q (get-value q)))
	     (ecase op
		((equalp) `(equalp ,p ,q))
		((not-equal-p) `(not (equalp ,p ,q)))
		((identicalp) `(identicalp ,p ,q))
		((not-identical-p) `(not-identical-p ,p ,q))
		((less-than-p) `(less-than-p ,p ,q))
		((less-than-or-equal-p) `(less-than-or-equal-p ,p ,q))
		((greater-than-p) `(greater-than-p ,p ,q))
		((greater-than-or-equal-p) `(greater-than-or-equal-p ,p ,q))
		((instanceof) `(php-object-instanceof ,p ,q)))))))

(define-method (generate-code node::boolean-not)
   (with-access::boolean-not node (p)
      `(not ,(get-boolean p))))

(define-method (generate-code node::boolean-or)
   (with-access::boolean-or node (p q)
      `(or ,(get-boolean p)
	   ,(get-boolean q))))

(define-method (generate-code node::boolean-and)
   (with-access::boolean-and node (p q)
      `(and ,(get-boolean p)
	    ,(get-boolean q))))

(define-method (generate-code node::boolean-xor)
   (with-access::boolean-xor node (p q)
      `(if ,(get-boolean p)
	   (if ,(get-boolean q)
	       #f
	       #t)
	   (if ,(get-boolean q)
	       #t
	       #f))))


;;;;typed stuff
(define (is-numeric? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(number) (var/gen-type thingy)))
       (eqv? 'number (node-return-type thingy))))

(define (is-hash? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(hash) (var/gen-type thingy)))
       ;don't actually know any cases where this would matter, but...
       (eqv? 'hash (node-return-type thingy))))

(define (is-string? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(string) (var/gen-type thingy)))
       (eqv? 'string (node-return-type thingy))))

(define-generic (get-copy rval)
;   `(copy-php-data ,
     (get-value rval) )
;     #f))

(define-method (get-copy rval::ast-node)
   (let ((ret-type (node-return-type rval)))
      (case ret-type
	 ;strings can't be mutated by any operators we've given them
	 ((boolean number string) (get-value rval))
	 (else `(copy-php-data ,(get-value rval))))))

(define-method (get-copy rval::literal-array)
   (get-value rval))

(define-method (get-copy rval::literal-null)
   (get-value rval))

(define-method (get-copy rval::function-invoke)
   (get-value rval))

(define-method (get-copy rval::method-invoke)
   (get-value rval))

(define-method (get-copy rval::constructor-invoke)
   (get-value rval))

(define (get-boolean node)
   (if (or ;(var/boolean? node)
	   (eqv? 'boolean (node-return-type node)))
       (get-value node)
       `(convert-to-boolean ,(get-value node))))



;;;;get-value
(define-generic (get-value rval)
;   (fprint (current-error-port) "get value caught a " rval)
   (if (eqv? rval :next)
       `:next
       `(maybe-unbox ',rval)))

(define-method (get-value rval::ast-node)
;   (fprint (current-error-port) "other get value caught a " rval)
          (generate-code rval));)))

(define-method (get-value rval::var-var)
   `(container-value ,(generate-code rval)))

(define-method (get-value rval::var)
   ;   (if (eqv? *current-var-var-env* '*current-variable-environment*);<-- this is even hackier! '*global-env*)    
   ;this is a hack so that we can share the global environment between
   ;the compiler and the interpreter.  I hope to replace it with just a
   ;vector-ref.
   ;       `(container-value (env-lookup *global-env* ,(undollar (var-name rval))));',(generate-code rval)))
   (if (var/gen-cont? rval)
       `(container-value ,(generate-code rval))
       (generate-code rval)))

(define-method (get-value rval::function-invoke)
   `(maybe-unbox ,(generate-code rval)))


(define-method (get-value rval::property-fetch)
   (generate-code rval))

(define-method (get-value rval::static-property-fetch)
   (generate-code rval))

(define-method (get-value rval::method-invoke)
   `(container-value ,(generate-code rval)))

(define-method (get-value rval::constructor-invoke)
   (generate-code rval))

(define-method (get-value rval::static-method-invoke)
   `(container-value ,(generate-code rval)))

(define-method (get-value rval::parent-method-invoke)
   `(container-value ,(generate-code rval)))

;;;;get-location
(define-generic (get-location rval)
   `(maybe-box ',rval))

(define-method (get-location rval::ast-node)
   ;note that this won't always return a container!
   ;this is used despite that, to allow us to share the global environment with interpreted code.
   (generate-code rval))

(define-method (get-location rval::hash-lookup)
   (with-access::hash-lookup rval (hash key)
      (let ((the-key (get-value key)))
	 (if (is-hash? hash)
	     `(php-hash-lookup-location ,(get-value hash) #f ,the-key)
	     `(begin
		 ,(update-value hash `(%coerce-for-insert ,(get-value hash)))
		 (%general-lookup-location ,(get-value hash) ,the-key))))))

(define-method (get-location rval::property-fetch)
   (with-access::property-fetch rval (location obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))	 
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc rval "property name is not a string, but should be."))
	 `(let* ((obj-evald ,the-object)
		 (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	     ; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
	     (set! *PHP-FILE* ,*file-were-compiling*)
	     (set! *PHP-LINE* ,(car location))	     
	     ,(generate-prop-visibility-check 'obj-evald the-property)
	     ,(if property-is-constant?
		  `(php-object-property-location/string
		    obj-evald ,(mkstr the-property) access-type)
		  `(php-object-property-location obj-evald ,the-property access-type))))))
   

(define-method (get-location rval::var)
       (generate-code rval));)

(define-method (get-location rval::function-invoke)
   `(maybe-box ,(generate-code rval)))

(define-method (get-location rval::method-invoke)
   (generate-code rval))

(define-method (get-location rval::constructor-invoke)
   `(make-container ,(generate-code rval)))

(define-method (get-location rval::static-method-invoke)
   (generate-code rval))

(define-method (get-location rval::parent-method-invoke)
   (generate-code rval))

;;;;update-value
(define-generic (update-value lval rval-code)
   (let ((rval-name (gensym 'rval)))
      `(let ((,rval-name ,rval-code))
	  (container-value-set! ,(generate-code lval) ,rval-name)
	  ,rval-name)))

(define-method (update-value lval::var/gen rval-code)
   (if (var/gen-cont? lval)
        (let (;(lval-code (var-name lval))
	      (rval-name (gensym 'rval)))
	   ;	  (add-binding-to-current-block lval-code '(make-container '()))
	   `(let ((,rval-name ,rval-code))
	       (container-value-set! ,(generate-code lval) ,rval-name)
	       ; 	      ,(if (eqv? *current-var-var-env* '*current-variable-environment*)
	       ; 		   ;XXX hack
	       ; 		   `(container-value-set!
	       ; 		     ;(env-lookup *global-env* ,(undollar lval-code))
	       ; 		     (env-index-),rval-name)
	       ; 		   `(container-value-set! ,lval-code ,rval-name))
	       ,rval-name))
       (let ((lval-code (var-name lval))
	     (rval-name (gensym 'rval)))
	  (add-binding-to-current-block lval-code ''())
	  `(let ((,rval-name ,rval-code))
	      ,(if (global-scope?)
		   `(container-value-set! (env-lookup *global-env* ,(undollar lval-code)) ,rval-name)
		   `(set! ,lval-code ,rval-name))
	      ;it's okay that this isn't in a container, because it's not an ast-node,
	      ;so get-value & get-location treat it differently
	      ,rval-name))))


(define-method (update-value lval::hash-lookup rval-code)
   ;;this and update-location of hash-lookup are similar messes
   ;;really, they do about the same thing
   (let ((rval-name (gensym 'rval)))
      ;;this is to make sure that any property-lookups or hash-lookups
      ;;that we get-value of will be "separated" -- have any pending lazy
      ;;copies forced
      (dynamically-bind (*hash-lookup-writable* #t)
	 (with-access::hash-lookup lval (hash key)
	    ;;when dealing with a nested (multi-dimensional) hash-lookup,
	    ;;pass the list of keys to %general-insert-n!, instead of
	    ;;trying to generate some fancy nested insert code, which ends
	    ;;up multiply-evaluating key forms
	    (if (hash-lookup? hash)
		(let loop ((keys (list (get-value key)))
			   (next hash))
		   (if (hash-lookup? next)
		       (with-access::hash-lookup next (hash key)
			  (loop (cons (get-value key) keys)
				hash))
		       `(let ((,rval-name ,rval-code))
			   ;;this is the base case.  make sure to return the rval,
			   ;;for cases like $a = $a[2] = $b[4]
			   ,(update-value next
					  `(%general-insert-n! (%coerce-for-insert ,(get-value next))
							       ,(maybe-emit-constant-list keys)
							       '(,@(map precalculate-string-hashnumber keys))
							       ,rval-name))
			   ,rval-name)))
                ;; this is the non-nested case
                (let* ((key (get-value key))
                       (pre (precalculate-string-hashnumber key)))
                   (if (is-hash? hash)
                       ;simpler version for typed var	
                       (if pre                           
                           `(php-hash-insert!/pre ,(get-value hash)
                                                  ,key
                                                  ,pre
                                                  ,rval-code)
                           `(php-hash-insert! ,(get-value hash)
                                              ,key
                                              ,rval-code))
                       ;hairy version for untyped var
                       `(let* ((,rval-name ,rval-code)
			       (hval (%coerce-for-insert ,(get-value hash)))
			       (uval ,(if pre
					  `(%general-insert!/pre
					    hval
					    ,key
					    ,pre
					    ,rval-name)
					  `(%general-insert!
					    hval
					    ,key
					    ,rval-name))))
			   (unless (php-object? hval)
			      ,(update-value hash `uval))
                           ,rval-name))))))))

(define-method (update-value lval::property-fetch rval-code)
   (with-access::property-fetch lval (location obj prop)
      (let* ((the-object (get-value obj))
            (the-property (if (ast-node? prop)
                              (get-value prop)
                              (mkstr prop)))
            (property-is-constant? (compile-time-constant? the-property)))
        (when (and property-is-constant? (not (string? the-property)))
           (warning/loc lval "property name is not a string, but should be."))
        `(let* ((obj-evald ,the-object)
                (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	    ; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
	    (set! *PHP-FILE* ,*file-were-compiling*)
	    (set! *PHP-LINE* ,(car location))	     	    
            ,(generate-prop-visibility-check 'obj-evald the-property)
            ,(if property-is-constant?
                 `(php-object-property-set!/string
                   obj-evald
                   ,(mkstr the-property)
                   ,rval-code
                   access-type)
                 `(php-object-property-set! obj-evald ,the-property ,rval-code access-type))))))

(define-method (update-value lval::static-property-fetch rval-code)
   (with-access::static-property-fetch lval (location class prop)
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) *current-parent-class-name*)
			       (else class))))
	 (if (and (eqv? class '%self)
		  (eqv? class-canon #f))
	     (delayed-error/loc lval "Cannot access self:: when no class scope is active")
	     (if (and (eqv? class '%parent)
		      (or (eqv? class-canon #f)))
		 (delayed-error/loc lval "Cannot access parent:: when current class scope has no parent")
		 (let* ((the-property (if (var-var? prop)
					  (get-value prop)
					  prop))
			(prop-name (undollar (var-name the-property))))		 
		    `(let* ((prop-evald ,prop-name)
			    (access-type ,(generate-get-static-prop-access-type class-canon 'prop-evald)))
			; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
			(set! *PHP-FILE* ,*file-were-compiling*)
			(set! *PHP-LINE* ,(car location))	     			
			,(generate-static-prop-visibility-check class-canon 'prop-evald)
			(php-class-static-property-set! ',class-canon ,prop-name ,rval-code access-type))))))))

;;;;unset
(define-generic (unset lval)
   (update-value lval ''()))
;   (error 'unset "don't know how to unset lval" lval))


(define-method (unset lval::var/gen)
   (with-access::var/gen lval (cont?)
      (if cont?
	  ; container: detach and set NULL
	  (update-location lval ''())
	  ; normal, set null
	  (update-value lval ''()))))

(define-method (unset lval::hash-lookup)
   (with-access::hash-lookup lval (hash key)
      (if (is-hash? hash)
	  `(php-hash-remove! ,(get-value hash) ,(get-value key))
	  (let ((hash-name (gensym 'hash)))
	     `(let ((,hash-name ,(get-value hash)))
		 (when (string? ,hash-name)
		    (php-error "Cannot unset string offsets"))
		 (if (and (php-object? ,hash-name) (php-object-instanceof ,hash-name "ArrayAccess"))
		     (call-php-method-1 ,hash-name "offsetUnset" ,(get-value key))
		     (when (php-hash? ,hash-name)
			(php-hash-remove! ,hash-name
					  ,(get-value key))) ) )))))

(define-method (unset lval::property-fetch)
   (with-access::property-fetch lval (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop))))
	 `(let* ((obj-evald ,the-object)
		 (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	     (if (and (php-object? obj-evald)
		      (php-class-method-exists?
		       (php-object-class obj-evald)
		       "__unset")
		      ; we call __unset when the caller doesn't have visibility access
		      ; (whether it's actually declared for real or not) or when it
		      ; would have visibility but it's not declared
		      (or  (pair? access-type) ; if access-type is a pair, it's not visible in this context
			   (not (php-object-has-declared-property?
				 obj-evald
				 ,the-property))))
		 (convert-to-boolean (call-php-method-1 obj-evald "__unset" ,the-property))
		 ; unset (remove) property
		 (php-object-property-unset obj-evald ,the-property))))))

;;;;isset
(define-generic (isset rval)
   `(not (null? ,(get-value rval))))

(define-method (isset rval::hash-lookup)
   (with-access::hash-lookup rval (hash key)
      `(let ((the-hash ,(get-value hash))
	     (the-key ,(get-value key)))
	  (if (and (php-object? the-hash) (php-object-instanceof the-hash "ArrayAccess"))
	      (convert-to-boolean (call-php-method-1 the-hash "offsetExists" the-key))
	      ; normal
	      (not (null? ,(get-value rval)))))))

(define-method (isset rval::property-fetch)
   (with-access::property-fetch rval (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop))))
	 `(let* ((obj-evald ,the-object)
		 (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	     (if (and (php-object? obj-evald)
		      (php-class-method-exists?
		       (php-object-class obj-evald)
		       "__isset")
		      ; we call __isset when the caller doesn't have visibility access
		      ; (whether it's actually declared for real or not) or when it
		      ; would have visibility but it's not declared
		      (or  (pair? access-type) ; if access-type is a pair, it's not visible in this context
			   (not (php-object-has-declared-property?
				 obj-evald
				 ,the-property))))
		 (convert-to-boolean (call-php-method-1 obj-evald "__isset" ,the-property))
		 ; normal isset
		 (not (null? ,(get-value rval))))))))

;;;;update-location
(define-generic (update-location lval rval-code)
   (error 'update-location-generic "unable to assign to location"
	  (cons lval rval-code)))


(define-method (update-location lval::var-var rval-code)
   (with-access::var-var lval (lval)
      (let ((name (gensym 'name))
	    (value (gensym 'val)))
	 `(let ((,name (mkstr ,(get-value lval)))
		(,value (maybe-box ,rval-code)))
	     (env-extend ,*current-var-var-env* ,name (maybe-box ,value))
	     ,@(refresh-lexicals)
	     ,value))))

(define (refresh-lexicals)
   (map (lambda (name)
	   `(set! ,name (env-lookup ,*current-var-var-env* ,(undollar name))))
	(cond
	   ((method-decl/gen? *current-block*)
	    (method-decl/gen-variable-names *current-block*))
	   ((function-decl/gen? *current-block*)
	    (function-decl/gen-variable-names *current-block*))
	   (else '()))))

(define-method (update-location lval::var/gen rval-code)
   (if (var/gen-cont? lval)
       (let ((name (var-name lval)))
	  (add-binding-to-current-block name '(make-container '()))
	  (if (global-scope?)
	      (let ((rval-name (gensym 'rval)))
		 `(let ((,rval-name ,rval-code))
		     (env-internal-index-value-set! ,name (maybe-box ,rval-name))
		     ,rval-name))
	      `(begin
		  (set! ,name ,rval-code)
		  (when ,*current-var-var-env*
		     (env-extend ,*current-var-var-env* ,(undollar name) ,name))
		  ,name)))
       (error 'update-location-var "tried to update the location of an unboxed variable" lval)))

(define-method (update-location lval::property-fetch rval-code)
   (with-access::property-fetch lval (location obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc lval "property name is not a string, but should be."))
	 `(let* ((obj-evald ,the-object)
		 (access-type ,(generate-get-prop-access-type 'obj-evald the-property)))
	     ; XXX LINE/FILE update only neeed while we do visibility checks here: they will be moved to runtime
	     (set! *PHP-FILE* ,*file-were-compiling*)
	     (set! *PHP-LINE* ,(car location))	     	     
	     ,(generate-prop-visibility-check 'obj-evald the-property)	 	 
	     ,(if property-is-constant?
		  `(php-object-property-set!/string
		    obj-evald ,(mkstr the-property) (maybe-box ,rval-code) access-type)
		  `(php-object-property-set! obj-evald ,the-property (maybe-box ,rval-code) access-type))))))


(define-method (update-location lval::hash-lookup rval-code)
   (let ((rval-name (gensym 'rval)))
      (dynamically-bind (*hash-lookup-writable* #t)
	 (with-access::hash-lookup lval (hash key)
	    (if (hash-lookup? hash)
		(let loop ((keys (list (get-value key)))
			   (next hash))
		   (if (hash-lookup? next)
		       (with-access::hash-lookup next (hash key)
			  (loop (cons (get-value key) keys)
				hash))
		       `(let ((,rval-name ,rval-code))
			   ,(update-value next
					  `(%general-insert-n! (%coerce-for-insert ,(get-value next))
							       ,(maybe-emit-constant-list keys)
                                                               '(,@(map precalculate-string-hashnumber keys))
							       ,rval-name))
			   ,rval-name)))
		(let* ((the-key (get-value key))
                       (pre (precalculate-string-hashnumber key)))
		   (cond
		      ;kludge for globals, since reference assignment doesn't do what you want there
		      ((and (var? hash) (eqv? '$GLOBALS (var-name hash)))
		       (update-value lval `(maybe-unbox ,rval-code)))
		      ((is-hash? hash)
                       (if pre
                           `(let ((,rval-name ,rval-code))
                               (php-hash-insert!/pre ,(get-value hash)
                                                     ,the-key
                                                     ,pre
                                                     ,rval-name))
                           `(let ((,rval-name ,rval-code))
                               (php-hash-insert! ,(get-value hash)
                                                 ,the-key
                                                 ,rval-name))))
		      (else
                       (if pre
                           `(let ((,rval-name ,rval-code))
                               ,(update-value hash `(%coerce-for-insert ,(get-value hash)))
                               (%general-insert!/pre ,(get-value hash) ,the-key ,pre ,rval-name)
                               ,rval-name)
                           `(let ((,rval-name ,rval-code))
                               ,(update-value hash `(%coerce-for-insert ,(get-value hash)))
                               (%general-insert! ,(get-value hash) ,the-key ,rval-name)
                               ,rval-name))))))))))

(define (maybe-emit-constant-list values)
   ;; use a constant (quoted) list where possible
   ;; we use this for n-dimensional hashtable insertions
   (let ((constant? (lambda (a)
                       (or (keyword? a)
                           ;; floats will be symbols due to fixup-onums
                           (and (php-number? a) (onum-long? a))
                           (string? a)))))
      (if (every constant? values)
          `'(,@values)
          `(list ,@values))))



;;;;utilities
(define (current-symtab)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-symbol-table *current-block*))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-symbol-table *current-block*))
      ((php-ast/gen? *current-block*)
       (php-ast/gen-global-symbol-table *current-block*))
      (else (error 'current-symtab "something is screwed" *current-block*))))

(define (current-static-vars)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-static-vars *current-block*))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-static-vars *current-block*))
      ((php-ast/gen? *current-block*) #f)
      (else (error 'current-static-vars "something is screwed" *current-block*))))

(define (flag-needs-var-var-env!)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-needs-env?-set! *current-block* #t))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-needs-env?-set! *current-block* #t))))


(define (global-bindings)
   (let ((code '()))
      (hashtable-for-each (current-symtab)
	 (lambda (key val)
	    (pushf `(,key (env-lookup-internal-index ,*current-var-var-env* ,(undollar key))) code)))
      code))

(define (bindings symbol-table exclude)
   ;;symbol-table is a hashtable of names and values
   ;;exclude is the ones that we shouldn't generate bindings for
   (let ((bindings '()))
      (hashtable-for-each symbol-table
	 (lambda (key type)
	    (unless (memv key exclude)
	       (pushf
		(if (superglobal? key)
		    ;this might not make the most sense, but works for superglobals which are hashtables.
		    `(,key (env-lookup *global-env* ,(undollar key)))
		    (cond
		       ((types-eqv? type 'container) `(,(symbol-append key '::pair) (make-container '())))
		       ((types-eqv? type 'number) `(,(symbol-append key '::onum) *zero*)) ;;onum?
		       ((types-eqv? type 'string) `(,(symbol-append key '::bstring) ""))
		       ((types-eqv? type 'hash) `(,(symbol-append key '::struct) (make-php-hash)))
		       (else `(,key '()))))
		bindings))))
      bindings))

(define (bindings-generate symbol-table container-table)
   ;like bindings, but call generate-code on the values
   (let ((bindings '()))
      (hashtable-for-each symbol-table
	 (lambda (key val)
	    (pushf (list key (if (superglobal? key)
				 ;this might not make the most sense, but works for superglobals which are hashtables.
				 `(env-lookup *global-env* ,(undollar key))
				 (let ((val-code			     
					(cond ((null? val) ''())
					      ((ast-node? val) (generate-code val))
					      (else val))))
				    (if (hashtable-get container-table key)
					`(maybe-box ,val-code)
					`(maybe-unbox ,val-code)))))
		   
		   bindings)))
      bindings))

; like bindings-generate but in the form of set! instead of a list for a let clause
(define (reset-bindings-generate symbol-table container-table)
   (let ((bindings '()))
      (hashtable-for-each symbol-table
	 (lambda (key val)
	    (pushf (let ((val-code			     
			  (cond ((null? val) ''())
				((ast-node? val) (generate-code val))
				(else val))))
		      (if (hashtable-get container-table key)
			  `(set! ,key (maybe-box ,val-code))
			  `(set! ,key (maybe-unbox ,val-code))))
		   bindings)))
      bindings))

(define (add-bindings-to-env symbol-table)
   (let ((code '()))
      (hashtable-for-each symbol-table
	 (lambda (key val)
	    (pushf `(env-extend ,*current-var-var-env* ,(undollar key) ,key) code)))
      code))

(define (add-arguments-to-env args)
   ;we assume that we'll never have more args than params, because PHP can't define
   ;var-arity functions, just optional params
    (let loop ((args args)
	       (code '()))
       (if (null? args)
	   code
	   (loop (cdr args)
		 (cons `(env-extend ,*current-var-var-env*
				    ,(undollar (formal-param-name (car args)))
				    ,(formal-param-name (car args)))
		       code)))))

(define (add-binding-to-current-block name value)
   ;; once upon a time, a list of all variables in a function was built
   ;; up using add-binding-to-current-block while generating code.  Now
   ;; the symbol table is used, and it should be populated already.  You
   ;; might expect it to be populated in the declare phase, but that would
   ;; be too easy.  It's populated by cfa, so that it serves as a sanity check.
   ;; Here, the old add-binding-to-current-block code is being used to verify
   ;; that no variables got missed.  
   (let ((symtab (current-symtab)))
      (unless (hashtable-get symtab name)
	 (if (ast-node? *current-block*)
	     (delayed-error/loc *current-block* (mkstr "variable "  name " not found in symtab"))
	     (delayed-error (mkstr "likely global, variable "  name " not found in symtab"))))))
   
(define (pass-argument from to)
   (if from
       ; to reference or not to reference
       (if (sig-param-ref? to)
	   (get-location from)
	   (get-value from)) ;maybe-copy
       (if (ast-node? (sig-param-default-value to))
	   (generate-code
	    (sig-param-default-value to))
	   (sig-param-default-value to))))

(define (typehint-checks class-name function-name decl-arglist)
   (let ((code '())
	 (argnum 0))
      (for-each (lambda (arg)
		   (set! argnum (+ 1 argnum))
		   (unless (null? (formal-param-typehint arg))
		      (let ((allow-null? (and (optional-formal-param? arg)
					      (literal-null? (optional-formal-param-default-value arg)))))
			 (if (eqv? '%array (formal-param-typehint arg))
			     (set! code (cons
					 `(unless (or (php-hash? ,(formal-param-name arg))
						      ,(if allow-null?
							   `(php-null? ,(formal-param-name arg))
							   `#f))
					     (php-recoverable-error
					      (format "Argument ~a passed to ~a() must be an array, ~a given, called in ~a on line ~a and defined"
						      ,argnum
						      ,(mkstr function-name)
						      (get-php-datatype ,(formal-param-name arg))
						      (get-stack-caller-file)
						      (get-stack-caller-line)
						      )))
					 code))
			     ; needs to be an object
			     (set! code (cons
					 `(unless (or (and (php-object? ,(formal-param-name arg))
							   (php-object-is-a ,(formal-param-name arg) ',(formal-param-typehint arg)))
						      ,(if allow-null?
							   `(php-null? ,(formal-param-name arg))
							   `#f))
					     ; to give the proper error, we need to know if the typehint is an interface or an object
					     (let ((emsg (if (php-class-is-interface? ',(formal-param-typehint arg))
							     (mkstr "implement interface " ',(formal-param-typehint arg))
							     (mkstr "be an instance of " ',(formal-param-typehint arg)))))
						(php-recoverable-error (format "Argument ~a passed to ~a() must ~a, ~a given, called in ~a on line ~a and defined"
									       ,argnum
									       ,(mkstr class-name "::" function-name)
									       emsg
									       (if (php-object? ,(formal-param-name arg))
										   (mkstr "instance of " (php-object-class ,(formal-param-name arg)))
										   (get-php-datatype ,(formal-param-name arg)))
									       (get-stack-caller-file)
									       (get-stack-caller-line)
									       ))))
					 code))))))
		decl-arglist)
      code))

(define (box-non-reference-container-args arglist)
   (map (lambda (a)
	   (with-access::formal-param a (name)
	      `(set! ,name (make-container ,name))))
	(filter (lambda (a)
		   (or (and (required-formal-param? a) (required-formal-param/gen-cont? a));(required-formal-param/cont? a)
		       (and (optional-formal-param? a) (optional-formal-param/gen-cont? a))));		       (optional-formal-param/cont? a)))
		arglist)))

(define (copy-and-type-non-reference-args arglist)
   (remove null?
	   (map (lambda (a)
		   (with-access::formal-param a (name ref?)
		      (cond
			 (ref? '())
			 ; 			 ((or (optional-formal-param/hash? a) (required-formal-param/hash? a))
			 ; 			  `(set! ,name (copy-php-data (convert-to-hash ,name) #f)))
			 ((or (and (required-formal-param/gen? a)
				   (not (required-formal-param/gen-needs-copy? a)))
			      (and (optional-formal-param/gen? a)
				   (not (optional-formal-param/gen-needs-copy? a))))
			  '())
			 (else
			  `(set! ,name (copy-php-data ,name)) ))))
		arglist)))



(define (runtime-sig location name toplevel? variable-arity? params)
   (let ((maximum-arity (if variable-arity? -1 (length params)))
	 (minimum-arity 0)
	 (store-routine (case (length params)
			   ((0) 'store-signature-0)
			   ((1) 'store-signature-1)
			   ((2) 'store-signature-2)
			   ((3) 'store-signature-3)
			   (else 'store-signature)))
	 
	 (brief-params '()))
      (map (lambda (a)
	      (if (required-formal-param? a)
		  (with-access::required-formal-param a (name ref?)
		     (set! minimum-arity (+fx minimum-arity 1))
		     (set! brief-params
			   (cons* (if ref? t-reference t-required)
				  `',name 0 brief-params)))
		  (with-access::optional-formal-param a (name default-value ref?)
		     (set! brief-params
			   (cons* (if ref? t-optional-reference t-optional)
				  `',name (if (and (literal-array? default-value)
						    (null? (literal-array-array-contents default-value)))
					       `'empty-hash
					       (get-value default-value)) brief-params)))))
	   (reverse params))
      (if toplevel?
	  `(,store-routine ,name ,ft-user-compiled ',location ',name ,minimum-arity ,maximum-arity ,@brief-params)
	  `(let ((sig (store-signature ,name ,ft-user-compiled ',location ',name ,minimum-arity ,maximum-arity ,@brief-params)))
	      (sig-function-set! sig ,name)))))



(define (calculate-class-heritage klass)
   "calculate a class's lineage"
   (let loop ((heritage '())
	      (klass klass))
      (if (convert-to-boolean klass)
	  (loop (cons (mkstr (symbol-downcase (class-decl-name klass))) heritage)
		(if (null? (class-decl-parent-list klass))
		    #f
		    (php-hash-lookup *class-decl-table* (symbol-downcase (car (class-decl-parent-list klass))))))
	  (reverse (cons "stdClass" heritage)))))


(define (compile-time-constant? x)
   (or (string? x)
       (php-number? x)
       (boolean? x)))

(define (trace-wrap class-name name param-names location . code)
   (if *track-stack?*
       (let ((retvalname (gensym 'ret)))
	  `((push-stack ',class-name ',name ,@param-names)
	    (set! *PHP-LINE* ,(car location))
	    (set! *PHP-FILE* ,*file-were-compiling*)
	    (let ((,retvalname (begin ,@code)))
	       (pop-stack)
	       ,retvalname)))
       code))

(define (profile-wrap name code)
   (if (not *source-level-profile*)
       code
       (let ((retvalname (gensym 'ret)))
	  `((profile-enter ',name)
	    (let ((,retvalname (begin ,@code)))
	       (profile-leave ',name)
	       ,retvalname)))))

(define (bind-exit-if condition exit-name code)
   (if condition
       `(bind-exit (,exit-name)
	   ,code)
       code))

(define (global-scope?)
   ;; are we currently in global scope?  I.e. should variables be treated
   ;; as globals.
   (eq? *current-var-var-env* '*current-variable-environment*))


(define (shared-env-wrap needs-env? code)
   (if (not needs-env?)
       code
       `(let ((env ,(if needs-env? '(env-new) #f))
	       (old-env *current-variable-environment*))
	   (set! *current-variable-environment* env)
	   (begin0
	    ,code
	    (set! *current-variable-environment* old-env)))))

