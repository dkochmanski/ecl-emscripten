;;; ----------------------------------------------------------------------
;;; Macros only used in the code of the compiler itself:

(in-package "COMPILER")
(import 'sys::arglist "COMPILER")

(defun same-fname-p (name1 name2) (equal name1 name2))

;;; from cmpenv.lsp
(defmacro next-cmacro () '(incf *next-cmacro*))

;;; from cmplabel.lsp
(defmacro next-label () `(cons (incf *last-label*) nil))

(defmacro next-label* () `(cons (incf *last-label*) t))

(defmacro wt-go (label)
  `(progn (rplacd ,label t) (wt "goto L" (car ,label) ";")))

;;; from cmplam.lsp
(defmacro ck-spec (condition)
  `(unless ,condition
           (cmperr "The parameter specification ~s is illegal." spec)))

(defmacro ck-vl (condition)
  `(unless ,condition
           (cmperr "The lambda list ~s is illegal." vl)))

;;; fromcmputil.sp
(defmacro cmpck (condition string &rest args)
  `(if ,condition (cmperr ,string ,@args)))

;;; from cmpwt.lsp
(defmacro wt (&rest forms &aux (fl nil))
  (dolist (form forms (cons 'progn (nreverse (cons nil fl))))
    (if (stringp form)
        (push `(princ ,form *compiler-output1*) fl)
        (push `(wt1 ,form) fl))))

(defmacro wt-h (&rest forms &aux (fl nil))
  (dolist (form forms)
    (if (stringp form)
      (push `(princ ,form *compiler-output2*) fl)
      (push `(wt-h1 ,form) fl)))
  `(progn (terpri *compiler-output2*) ,@(nreverse (cons nil fl))))

(defmacro princ-h (form) `(princ ,form *compiler-output2*))

(defmacro wt-nl (&rest forms)
  `(wt #\Newline #\Tab ,@forms))

(defmacro wt-nl1 (&rest forms)
  `(wt #\Newline ,@forms))

(defmacro safe-compile ()
  `(>= *safety* 2))

(defmacro compiler-check-args ()
  `(>= *safety* 1))

(defmacro compiler-push-events ()
  `(>= *safety* 3))

;; ----------------------------------------------------------------------
;; C1-FORMS
;;

(defstruct (c1form (:include info)
		   (:print-object print-c1form)
		   (:constructor do-make-c1form))
  (name nil)
  (parent nil)
  (args '()))

(defun print-c1form (form stream)
  (format stream "#<form ~A ~X>" (c1form-name form) (ext::pointer form)))

(defun make-c1form (name subform &rest args)
  (let ((form (do-make-c1form :name name :args args
			      :type (info-type subform)
			      :sp-change (info-sp-change subform)
			      :volatile (info-volatile subform))))
    (c1form-add-info form args)
    form))

(defun make-c1form* (name &rest args)
  (let ((info-args '())
	(form-args '()))
    (do ((l args (cdr l)))
	((endp l))
      (let ((key (first l)))
	(cond ((not (keywordp key))
	       (baboon))
	      ((eq key ':args)
	       (setf form-args (rest l))
	       (return))
	      (t
	       (setf info-args (list* key (second l) info-args)
		     l (cdr l))))))
    (let ((form (apply #'do-make-c1form :name name :args form-args
		       info-args)))
      (c1form-add-info form form-args)
      form)))

(defun c1form-add-info (form dependents)
  (dolist (subform dependents form)
    (cond ((c1form-p subform)
	   (when (info-sp-change subform)
	     (setf (info-sp-change form) t))
	   (setf (c1form-parent subform) form))
	  ((consp subform)
	   (c1form-add-info form subform)))))

(defun copy-c1form (form)
  (copy-structure form))

(defmacro c1form-arg (nth form)
  (case nth
    (0 `(first (c1form-args ,form)))
    (1 `(second (c1form-args ,form)))
    (otherwise `(nth ,nth (c1form-args ,form)))))

(defun c1form-volatile* (form)
  (if (c1form-volatile form) "volatile " ""))

(defun c1form-primary-type (form)
  (let ((type (c1form-type form)))
    (when (and (consp type) (eq (first type) 'VALUES))
      (let ((subtype (second type)))
	(when (or (eq subtype '&optional)	(eq subtype '&rest))
	  (setf subtype (third (c1form-type form)))
	  (when (eq subtype '&optional)
	    (cmperr "Syntax error in type expression ~S" type)))
	(when (eq subtype '&rest)
	  (cmperr "Syntax error in type expression ~S" type))
	(setf type subtype)))
    type))

(defun find-node-in-list (home-node list)
  (flet ((parent-node-p (node presumed-child)
	   (loop
	    (cond ((null presumed-child) (return nil))
		  ((eq node presumed-child) (return t))
		  (t (setf presumed-child (c1form-parent presumed-child)))))))
    (member home-node list :test #'parent-node-p)))
