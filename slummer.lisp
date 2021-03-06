;;;; slummer.lisp

(named-readtables:in-readtable :parenscript)
(in-package #:slummer)

(defparameter +slummer-version+ '(0 4 1))

;; the default is 1.3
(setf ps:*js-target-version* "1.8.5")

;;; Parenscript Macros

;; NB: The following macro exists b/c ps:{} wasn't working for some reason
(defpsmacro {} (&rest args)
  "A convenience macro for building object literals."
  `(ps:create ,@args))

(defpsmacro @> (&rest args)
  "A convenience macro aliasing ps:chain."
  `(ps:chain ,@args))

(defpsmacro setf+ (place val)
  (if (consp place)
      (destructuring-bind (accessor object) place
        `(,(setf-name-of accessor) ,val ,object))
      `(setf ,place ,val)))


(defpsmacro let-slots (slot-specs &rest body)
  (if (consp slot-specs)
      `(with-slots ,(caar slot-specs) ,(cadar slot-specs)
         (let-slots ,(cdr slot-specs) ,@body))
      `(progn ,@body)))


(defpsmacro with-methods (methods object &rest body)
  `(labels ,(mapcar #'(lambda (method)
                        `(,method (&rest args)
                                  (apply (getprop ,object ',method) args)))
                      methods)
     ,@body))

(defpsmacro with-object (object slots methods &rest body)
  "A convenience macro that combines with-slots and with-methods a single call.
It departs from the ordinary calling order by putting the expression that
evaluates to the object first.
 E.g.

(with-object (@> gonna make a (cool-thing 1 2 3)) (slot1 slot2) (method1 method2)
  .... do stuff)
"
  `(let ((object ,object))
     (with-slots ,slots object
       (with-methods ,methods object
         ,@body))))

(defun constructor-name-of (name) (read-from-string (format nil "make-~a" name)))
(defun accessor-name-for (name slot) (read-from-string (format nil "~a-~a" name slot)))
(defun getf-accessor-name-for (name slot)
  (read-from-string (format nil "__setf_~a-~a" name slot)))

(defpsmacro defstruct (name &rest slots)
  "SLOTS is either a symbol or a pair (SLOT-NAME INIT-VAL). Creates a function
  called MAKE-<NAME> and an access for each slot called <NAME>-<SLOT> that works
  with SETF."
  `(progn
     (defun ,(read-from-string (format nil "make-~a" name))
         (&key ,@slots)
       ({} struct ',name
           ,@(mapcan (lambda (slot)
                       (if (listp slot)
                           (list (car slot) (car slot))
                           (list slot slot)))
                     slots)))
     ,@(mapcar (lambda (slot)
                 (let* ((slot (if (listp slot) (car slot) slot))
                        (accessor-name (accessor-name-for name slot)))
                   `(progn
                      (defun ,accessor-name (ob)
                        (@> ob ,slot))
                      (defun (setf ,accessor-name) (new-val ob)
                        (setf (@> ob ,slot) new-val)))))
                 slots)))

(defpsmacro defmethod (name lambda-list &body body)
  (let ((profile (string-downcase
                  (cl-strings:join
                   (loop for e in lambda-list
                         collect (if (consp e)
                                     (format nil "~a" (second e))
                                     "__unspecified__")))))
        (arg-list (loop for e in lambda-list
                        collect (if (consp e) (car e) e))))
    `(progn
       (defvar ,name
         (lambda (&rest args)
           (let ((profile ""))
             (dolist (arg args)
               (if (not (equal "undefined" (typeof (ps:@ arg struct))))
                   (setf profile (+ profile (ps:@ arg struct)))
                   (setf profile (+ profile "__unspecified__"))))
             (apply (getprop ,name profile) args))))

       (setf (getprop ,name ,profile) (lambda ,arg-list ,@body)))))




(defpsmacro defelems (&rest names)
  "Used to define virtual DOM elements constructors en masse."
  (unless (null names)
    `(progn
      (defun ,(car names) (props &rest children)
        (elem ,(string-downcase (symbol-name (car names))) props children))
      (defelems ,@(cdr names)))))

(defun parse-route-template (template)
  (assert (equal #\# (elt template 0)))
  (let ((parts (cl-strings:split template #\/)))
    (cons (car parts) (mapcar #'read-from-string (cdr parts)))))

(defpsmacro defroute (template &body body)
  (let* ((parsed (parse-route-template template))
         (fname (gensym (format nil "~a-route" (car parsed)))))
    `(progn
       (defun ,fname ,(cdr parsed) ,@body)
       (@> window
           (add-event-listener
            "hashchange"
            (lambda ()
              (let ((parts (@> window location hash (split "/"))))
                (when (equal (ps:@ parts 0) ,(car parsed))
                  (apply ,fname (@> parts (slice 1)))))))))))

(defpsmacro defstate (name &optional (value (list 'ps:create)))
  `(defvar ,name
     ((lambda ()
        (let ((view-registry (ps:[])))
          (ps:new
           (-Proxy ,value
                   (ps:create
                    get (lambda (obj prop)
                          (if (equal prop "__registry") view-registry
                              (ps:getprop obj prop)))
                    set (lambda (obj prop newval)
                          (if (equal prop "__registry")
                              (progn
                                (setf (getprop view-registry prop) newval)
                                true)
                              (progn
                                (setf (getprop obj prop) newval)
                                (dolist (view view-registry)
                                  (@> *slummer* (render-view view)))
                                true)))))))))))



(defpsmacro defview (name state-vars handler-bindings render)
  `(defun ,name (attachment ,@state-vars)
     (labels ,handler-bindings
       (let ((view-ob
               (ps:create virtual nil
                          attachment (if (stringp attachment)
                                         (@> document (get-element-by-id attachment))
                                         attachment)
                          render (lambda () ,render))))
         (dolist (state-var (ps:[] ,@state-vars))
           (@> state-var "__registry" (push view-ob)))
         (@> *slummer* (render-view view-ob))
         view-ob))))


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


(defun setf-name-of (name)
  (read-from-string (format nil "__setf_~a" name)))

(defpsmacro export (&rest names)
  "To be called within the body a DEFMODULE. Exports NAMES from the containing
module. If a name is a SETF DEFUN, it will export the SETF version as well."
  (let* ((name-exports (loop for name in names collect
                             `(setf (@ *exports* ,name) ,name)))
         (setf-names (loop for name in names
                           collect (setf-name-of name)))
         (setf-name-exports (loop for name in setf-names
                                  collect `(when (equal "function" (typeof ,name))
                                             (setf (@ *exports* ,name) ,name)))))
    `(progn
       ,@(nconc name-exports setf-name-exports))))


(defpsmacro defunpub (name ll &body body)
  `(progn
     (defun ,name ,ll ,@body)
     (export ,name)))

(defpsmacro import-from (module-name &rest symbs)
  "To be called from within the body of DEFMODULE. Imports names into the
current module. Each member of SYMBS can be either a symbol or a pair of
symbols. In the case of the example pair (EXTERNAL LOCAL) the EXTERNAL symbol
is bound to the LOCAL symbol.  This lets you avoid name conflicts."
  (let* ((imports
           (mapcar (lambda (s)
                     (let* ((local (if (symbolp s) s (cadr s)))
                            (foreign (if (symbolp s) s (car s))))
                       (if (symbolp module-name)
                           `(progn
                              (defvar ,local (@ ,module-name ,foreign))
                              (defvar ,(setf-name-of local)
                                (@ ,module-name ,(setf-name-of foreign))))
                           `(progn
                              (defvar ,local (@ ,@(append module-name (list foreign))))
                              (defvar ,(setf-name-of local)
                                (@ ,@(append module-name (list (setf-name-of foreign)))))))))
                   symbs)))
    `(progn ,@imports)))


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
      (format t "WARNING: Already added ~s to site. Skippping.~%" path)
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

(defun print-version ()
  (destructuring-bind (major minor bugfix) +slummer-version+
    (format t "you have the honor of using slummer version ~a.~a.~a~%"
            major minor bugfix)))


(defparameter +commands+
  (list "slummer build"
        "slummer run"
        "slummer version"
        "slummer new <name>"))

(defun slum-it ()
  (let* ((args sb-ext:*posix-argv*)
         (arg-length (length args)))

    (cond ((and (= 2 arg-length)
                (equal "run" (string-downcase (second args))))
           (slumit-run-site))

          ((and (= 2 arg-length)
                (equal "build" (string-downcase (second args))))
           (slumit-build "main.lisp"))

          ((and (= 2 arg-length)
                (equal "version" (string-downcase (second args))))
           (print-version))

          ((and (= 3 arg-length)
                (equal "new" (string-downcase (second args))))
           (slumit-new (third args)))

          (t
           (format t "USAGE: ~a~%" (car +commands+))
           (format t "~{       ~a~%~}" (cdr +commands+))))))



(defun slumit-build (file)
  (load file))


(defun compile-input-p (path)
  (let ((name (file-namestring path)))
    (and (not (equal #\. (elt name 0)))
         (or (cl-strings:ends-with name ".paren")
             (cl-strings:ends-with name ".lisp")
             (cl-strings:ends-with name ".lass")))))


(defun should-recompile (watch-dict)
  (let ((changed nil))
    (cl-fad:walk-directory
     "."
     (lambda (p)
       (when (compile-input-p p)
         (let ((current-md5 (md5:md5sum-file p))
               (stored-md5 (gethash p watch-dict)))
           (when (not (equalp current-md5 stored-md5))
             (setf (gethash p watch-dict) current-md5)
             (setf changed t))))))
    changed))

(defun slumit-run-site ()
  (let ((server (hunchentoot:start
                 (make-instance 'hunchentoot:easy-acceptor
                                :port 5000)))
        (watch-dict (make-hash-table :test 'equalp)))
    (setf (hunchentoot:acceptor-document-root server)
          "build/")

    (format t "~%Visit http://127.0.0.1:5000/index.html in your browser.~%")
    (format t "Press Ctl-C to exit the test serer environment.~%")

    (handler-case
        (loop do
          (handler-case
              (progn
                (when (should-recompile watch-dict)
                  (format t "Building project ...~%")
                  (slumit-build "main.lisp"))
                (sleep 1))
            (error (c)
              (format *error-output* "~%~%Caught error during rebuild:~% ~s~%~%" c)
              (format t "Press Enter to continue when you think its ok...~%")
              (read-line)
              (format t "... Continuing!~%~%"))))

      (sb-sys:interactive-interrupt (c)
        (declare (ignore c))
        (format t "Exiting~%")
        (hunchentoot:stop server)
        (return-from slumit-run-site)))))




(defparameter +site-template+ "
(defpackage #:~a
  (:use #:cl #:slummer))

(in-package #:~a)

(defparameter +made-with-version+ '~a)

;; variable holding the site
(defvar *~a-site*)
(setf *~a-site* (fresh-site))

;; A site context section.
;; You can add more if you want to define pages
;; in different contexts.
(with-site-context (*~a-site*) ; add context keywords if you need them

  (include \"app.paren\")
  (include \"style.lass\")

  (defpage \"index.html\" (:scripts (\"app.js\") :styles (\"style.css\"))
    (:h1 \"Hello, Click Fiend.\")
    (:div :id \"clicker-1\")
    (:div :id \"clicker-2\" ))
  )

(build-site *~a-site*)
")

(defparameter +app-template+ "
(defmodule *~a*

  ;;; IMPORTS
  (import-from (*slummer* *html*) h1 p div button)
  (import-from *slummer* attach-view on)
  (import-from (*slummer* *util*) list)

  ;;; MODULE CODE

  (defun make-counter-state ()
    ({} count 0))

  (defstate first-counter (make-counter-state))
  (defstate second-counter (make-counter-state))

  (defview main-view (state)
    ((inc-clicks () (incf (@> state count))))
    (div ()
         (p () (@> state count))
         (button ({} :onclick inc-clicks) \"click me\")))

  (on window \"load\"
      (lambda ()
        (main-view \"clicker-1\" first-counter)
        (main-view \"clicker-2\" second-counter))))
")

(defparameter +style-template+ "
(:let ((text-color \"#f5f0e8\"))
  (body
   :color #(text-color)
   :background-color \"#454545\")

  (button
   :background-color \"#b00b51\"
   :border none
   :padding 10px 30px
   :font-size 16px
   :color #(text-color)))
")

(defun write-style-template (stream)
  (format stream +style-template+))

(defun write-site-template (stream name)
  (format stream +site-template+ name name +slummer-version+ name name name name))

(defun write-app-template (stream name)
  (format stream +app-template+ name))

(defun slumit-new (path)

  (let* ((path (if (cl-strings:ends-with path "/")
                   path
                   (concatenate 'string path "/")))
         (name (cadr (reverse (cl-strings:split path "/")))))

    (ensure-directories-exist path)
    (with-open-file (out (concatenate 'string path "/main.lisp") :direction :output)
      (write-site-template out name))
    (with-open-file (out (concatenate 'string path "/app.paren") :direction :output)
      (write-app-template out name))
    (with-open-file (out (concatenate 'string path "/style.lass") :direction :output)
      (write-style-template out))))




