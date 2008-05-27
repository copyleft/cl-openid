;;; -*- lisp -*- shelf.lisp: set up library pathnames and load shelf definition.
(require 'asdf)

(defpackage #:skel.shelf
  (:use #:common-lisp))
(in-package #:skel.shelf)

(defvar *topdir*
  (make-pathname :defaults (or *load-pathname*
                               *default-pathname-defaults*)
                 :name nil :type nil :version nil))

(defun subdir (subdir &optional (base-dir *topdir*))
  (merge-pathnames (make-pathname :directory `(:relative ,subdir))
                   base-dir))

(unless (find-package :cl-librarian)
  (pushnew (subdir "lib") asdf:*central-registry* :test #'equal)
  (asdf:operate 'asdf:load-op :cl-librarian))
(use-package :cl-librarian)

(defshelf cl-openid.deps (hunchentoot) ; e.g.
  ((usocket tarball-repo :source "asdf-install:usocket")
   (puri tarball-repo :source "asdf-install:puri")
   (drakma tarball-repo :source "http://weitz.de/files/drakma.tar.gz")
   (ironclad tarball-repo :source "http://www.method-combination.net/lisp/files/ironclad.tar.gz")

   (xmls tarball-repo :source "http://common-lisp.net/project/xmls/xmls-1.2.tar.gz")

   ;; 5am testing
   (arnesi darcs-repo :source "http://common-lisp.net/project/bese/repos/arnesi_dev/")
   (fiveam darcs-repo :source "http://common-lisp.net/project/bese/repos/fiveam/"))
  :directory (subdir "lib"))

