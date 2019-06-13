;;;; slummer.lisp

(named-readtables:in-readtable :parenscript)
(in-package #:slummer)

;;; Parenscript Macros

;; NB: The following macro exists b/c ps:{} wasn't working for some reason
(defpsmacro {} (&rest args)
  "A convenience macro for building object literals."
  `(ps:create ,@args))

(defpsmacro @> (&rest args)
  "A convenience macro aliasing ps:chain."
  `(ps:chain ,@args))

(defpsmacro defelems (&rest names)
  "Used to define virtual DOM elements constructors en masse."
  (unless (null names)
    `(progn
      (defun ,(car names) (props &rest children)
        (elem ,(string-downcase (symbol-name (car names))) props children))
      (defelems ,@(cdr names)))))


(defpsmacro defapp (name &rest setup)
  "Define an application, returns a function that accepts a DOM node. In the
body of your definition you must (SETF *VIEW* <something>) in order for your
app to work properly."
  `(defun ,name (attachment)
     (let* ((*state* nil)
            (*view* nil)
            (*virutal* nil)
            (*attachment* (if (stringp attachment)
                              (@> document (get-element-by-id attachment))
                              attachment))
            (*render* (lambda ()
                        (let ((new-virtual (*view*)))
                          (chain *slummer* (update-elem *attachment* *virtual* new-virtual))
                          (setf *virtual* new-virtual)))))
       (progn ,@setup)
       (setf *virtual* (*view*))
       (chain *slummer* (update-elem *attachment* nil *virtual*)))))

(defpsmacro defactive (name lambda-list &rest body)
  "A macro to be called within the body of a DEFAPP. Creates a function that,
after having been called, will re-render the DOM."
  `(defun ,name ,lambda-list
     (progn ,@body)
     (*render*)))

(defpsmacro defview (name view-form)
  "Defines a thunk that returns a virtual DOM element."
  `(defun ,name () ,view-form))

(defpsmacro defmodule (name &rest body)
  "Defines a unit of code, meant to encapsulate hidden state and functions. NAME
can be either a symbol or a list of symbols. In the latter case, the list
represents a module path to the module being defined."
  (cond
    ((symbolp name)
     `(defvar ,name
        ((lambda ()
           (let ((*exports* ({})))
             (progn ,@body)
             *exports*)))))

    ((listp name)
     `(setf (@ ,@name)
            ((lambda ()
               (let ((*exports* ({})))
                 (progn ,@body)
                 *exports*)))))))


(defpsmacro export (&rest names)
  "To be called within the body a DEFMODULE. Exports a NAMES from the containing module."
  `(progn
     ,@(mapcar (lambda (name)
                 (list 'setf (list '@ '*exports* name) name))
               names)))

(defpsmacro import-from (module-name &rest symbs)
  "To be called from within the body of DEFMODULE. Imports names into the
current module. Each member of SYMBS can be either a symbol or a pair of
symbols. In the case of the example pair (EXTERNAL LOCAL) the EXTERNAL symbol
is bound to the LOCAL symbol.  This lets you avoid name conflicts."
  `(progn ,@(mapcar (lambda (s)
                      (let ((local (if (symbolp s) s (cadr s)))
                            (foreign (if (symbolp s) s (car s))))
                        (if (symbolp module-name)
                            (list 'defvar local (list '@ module-name foreign))
                            (list 'defvar local (append (cons '@ module-name) (list foreign))))))
                      symbs)))


;;; Spinneret Macros & Functions

(defvar *js-root* ""
  "This special variable designates a URI root prepended to javascript file
  names passed to DEFPAGE.")

(defvar *css-root* ""
  "This special variable designates a URI root prepended to stylsheet file names
  that are passed to DEFPAGE")

(defvar *media-root* ""
  "Special variable to control where included media should be deposited.")

(defvar *site-root* "")

(defvar *site-data*) ; YOU MUST PROVIDN BINDINGS FOR THIS BEFORE CALLING ANY OF
                                        ; THE DEF-THING FUNCTIONS

(defvar *site-wide-scripts* '("psprelude.js" "slummer.js"))
(defvar *site-wide-styles* '())


(defmacro with-site-context ((site &key root js css media) &body body)
  `(let ((slummer::*site-data* ,site)
         (slummer::*site-root* (if ,root ,root slummer::*site-root*)) 
         (slummer::*js-root* (if ,js ,js slummer::*js-root*))
         (slummer::*css-root* (if ,css ,css slummer::*css-root*))
         (slummer::*media-root* (if ,media ,media slummer::*media-root*)))
     (progn ,@body)
     ;; add js preludes to site
     (add-js-preludes-to-site ,site)
     slummer::*site-data*))


(defun fresh-site ()
  "Creates a fresh site data object"
  (list :site))

(defun add-to-site (path thing)
  "Adds THING to the site stored in *SITE-DATA*, associating the PATH with that THING."
  (if (assoc path (cdr *site-data*) :test #'equal)
      (format t "WARNING: Already added ~s to site. Skippping." path)
      (push (cons path thing) (cdr *site-data*))))

(defun add-js-preludes-to-site (site)
  "Adds slummer.js and psprelude.js to the *SITE-DATA*"
  (let ((*site-data* site))
    (add-to-site (concatenate 'string *js-root* "psprelude.js")
                 (ps:ps* ps:*ps-lisp-library*))
    (add-to-site (concatenate 'string *js-root* "slummer.js")
                 (ps:ps* *slummer-ps-lib*))))


;; helper for use in defpage
(defun make-scripts (&optional source-names)
  (mapcar (lambda (s)
            (list :tag :name "script"
                       :attrs `(list :src (concatenate 'string *js-root* ,s))))
          (append *site-wide-scripts* source-names)))

;; helper for use in defpage
(defun make-styles (&optional source-names)
  (mapcar (lambda (s)
            (list :tag :name "link"
                       :attrs `(list :rel "stylesheet" :type "text/css"
                                     :href (concatenate 'string *css-root* ,s))))
          (append slummer::*site-wide-styles* source-names)))


(defmacro defpage (path (&key (title "Slumming It") styles scripts)  &body body)
  `(add-to-site
    ,path
    (spinneret:with-html-string
      (:doctype)
      (:html
       (:head
        (:title ,title)
        ,@(make-styles styles))
       (:body
        (:div ,@body)
        ,@(make-scripts scripts))))))

(defmacro defscript (script-name &body body)
  `(add-to-site (concatenate 'string *js-root* "/" ,script-name)
                (ps:ps ,@body)))

(defmacro defstyle (style-name &body body)
  `(add-to-site (concatenate 'string *css-root* "/" ,style-name)
                (lass:compile-and-write ,@body)))

;; helper to change a filename's extension, used for changing parenscript names to js names.
(defun change-filename-ext (name ext)
  (cl-strings:join
   (reverse
    (cons ext
          (cdr
           (reverse (cl-strings:split name ".")))))
   :separator "."))

(defun include-file-type (filename)
  (let ((ext (string-downcase (pathname-type filename))))
    (cond ((equal ext "paren")  :parenscript)
          ((equal ext "lass" ) :lass)
          (t :copy))))

(defun make-target-filename (filepath)
  "Isolates filename from FILEPATH and does two things: (1) Changes extensions
   .paren to .js and .lass to .css; (2) Prepends file type specific prefix to
   the name. I.e. *JS-ROOT* for .js, *MEDIA-ROOT* for media files, etc."
  (let ((ext (string-downcase (pathname-type filepath)))
        (filename (pathname-name filepath)))
    (cond ((member ext '("js" "paren") :test #'equal)
           (concatenate 'string *js-root* filename ".js"))
          ((member ext '("css" "lass") :test #'equal)
           (concatenate 'string *css-root* filename ".css"))
          ((member ext '("html" "htm") :test #'equal)
           (concatenate 'string *site-root* filename "." ext))
          (t (concatenate 'string *media-root* filename "." ext)))))


(defun include (filename &optional target)
  (add-to-site (if target target (make-target-filename filename))
               (cons (include-file-type filename) filename)))


;; *SITE-DATA* is a list of (PATH . CONTENT) pairs. PATH is where CONTENT will,
;; after having been interpreted, end up being written, relative to TARGET.
;; CONTENT can be any one of:
;; 1. A string
;; 2. A pair (FILE-TYPE . PATH) where PATH is realtive to
;;    the directory in which BUILD-SITE. FILE-TYPE is one of
;;    - :COPY
;;    - :PARENSCRIPT
;;    - :LASS
;;    - :SPINNERET
;;
;; For all file types except :COPY, the file will first be read into lisp in the
;; current environment, and, using the appropriate library, will be compiled to
;; a string which is then written to disk.

(defun build-site (site-data &optional (target "build/"))
  (loop for (path . content) in (cdr site-data)
        do (progn
             (let ((filename (concatenate 'string target path)))
               (ensure-directories-exist (directory-namestring filename))
               (build-content filename content)))))


(defun build-content (target-path content)
  (if (stringp content)
      (alexandria:write-string-into-file content target-path :if-exists :supersede)
      (destructuring-bind (file-type . source-path) content
        (print content)
        (case file-type
          (:copy (cl-fad:copy-file source-path target-path :overwrite t))
          (:parenscript
           (alexandria:write-string-into-file
            (ps:ps-compile-file source-path)
            target-path
            :if-exists :supersede))
          (:lass
           (lass:generate source-path :out target-path :pretty t))
          (:spinneret (error "not yet implemented"))))))

;;; slum-it

(defun slum-it ()
  (let ((args sb-ext:*posix-argv*))
    (if (= 2 (length args))
        (load (second args))
        (format t "USAGE: slummer <site-def.lisp>~%"))))
