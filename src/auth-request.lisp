(in-package #:cl-openid)

(defun indirect-request-uri (endpoint parameters
                             &aux
                             (uri (if (uri-p endpoint)
                                      (copy-uri endpoint)
                                      (uri endpoint)))
                             (q (drakma::alist-to-url-encoded-string ; FIXME: use of unexported function
                                 (acons "openid.ns" "http://specs.openid.net/auth/2.0"
                                        parameters)
                                 :utf-8)))
  (setf (uri-query uri)
        (if (uri-query uri)
            (concatenate 'string (uri-query uri) "&" q)
            q))
  uri)

(defun request-authentication-uri (id &key return-to realm immediate-p
                                   &aux (association (associate id)))
  (unless (or return-to realm)
    (error "Either RETURN-TO, or REALM must be specified."))
  (indirect-request-uri (aget :op-endpoint-url id)
                        `(("openid.mode" . ,(if immediate-p
                                                "checkid_immediate"
                                                "checkid_setup"))
                          ("openid.claimed_id" . ,(princ-to-string (aget :claimed-id id)))
                          ("openid.identity" . ,(or (aget :op-local-identifier id)
                                                    (princ-to-string (aget :claimed-id id))))
                          ,@(when association
                                  `(("openid.assoc_handle" . ,(association-handle association))))
                          ,@(when return-to
                                  `(("openid.return_to" . ,(princ-to-string return-to))))
                          ,@(when realm
                                  `((,(if (equal '(2 . 0)  ; OpenID 1.x compat: trust_root instead of realm
                                                 (aget :protocol-version id))
                                          "openid.realm"
                                          "openid.trust_root")
                                      . ,(princ-to-string realm)))))))

(defmacro string-case (keyform &body clauses)
  (let ((key (gensym "key")))
    `(let ((,key ,keyform))
       (declare (ignorable ,key))
       (cond
	 ,@(loop
	       for (keys . forms) in clauses
	       for test = (etypecase keys
			    (string `(string= ,key ,keys))
			    (sequence `(find ,key ',keys :test 'string=))
			    ((eql t) t))
	       collect
		 `(,test ,@forms))))))

(define-condition openid-assertion-error (error)
  ((message :initarg :message :reader message)
   (message-format-parameters :initarg :message-format-parameters :reader message-format-parameters)
   (id :initarg :id :reader id)
   (assertion :initarg :assertion :reader assertion))
  (:report (lambda (e s)
             (format s "OpenID assertion error: ~?"
                     (message e) (message-format-parameters e)))))

(defvar *nonces* nil)

;;; FIXME: roll into a MACROLET.
(defmacro %err (message &rest args)
  `(error 'openid-assertion-error
          :message ,message
          :message-format-parameters (list ,@args)
          :assertion parameters
          :id id))

(defmacro %check (test message &rest args)
  `(unless ,test
     (%err ,message ,@args)))

(defmacro %uri-matches (id-field parameters-field)
  `(uri= (uri (aget ,id-field id))
         (uri (aget ,parameters-field parameters))))

(defun handle-indirect-reply (parameters id uri
                              &aux (v1-compat (not (equal '(2 . 0) (aget :protocol-version id)))))
  (string-case (aget "openid.mode" parameters)

    ("setup_needed" :setup-needed)

    ("cancel" nil)
    ("id_res" ;; FIXME: verify

     ;; 11.1.  Verifying the Return URL
     (%check (uri= uri (uri (aget "openid.return_to" parameters)))
             "openid.return_to ~A doesn't match server's URI" (aget "openid.return_to" parameters))

     ;; 11.2.  Verifying Discovered Information
     (unless v1-compat
       (%check (string= "http://specs.openid.net/auth/2.0" (aget "openid.ns" parameters))
               "Wrong namespace ~A" (aget "openid.ns" parameters)))

     (unless (and v1-compat (null (aget "openid.op_endpoint" parameters)))
       (%check (%uri-matches :op-endpoint-url "openid.op_endpoint")
               "Endpoint URL does not match previously discovered information."))

     (unless (or (and v1-compat (null (aget "openid.claimed_id" parameters)))
                 (%uri-matches :claimed-id "openid.claimed_id"))
       (let ((cid (discover (normalize-identifier (aget "openid.claimed_id" parameters)))))
         (if (uri= (aget :op-endpoint-url cid)
                   (aget :op-endpoint-url id))
             (setf (cdr (assoc :claimed-id id))
                   (aget :claimed-id cid))
             (%err "Received Claimed ID ~A differs from user-supplied ~A, and discovery for received one did not find the same endpoint."
                   (aget :op-endpoint-url id) (aget :op-endpoint-url cid)))))

     ;; 11.3.  Checking the Nonce
     (%check (not (member (aget "openid.response_nonce" parameters) *nonces*
                          :test #'string=))
             "Repeated nonce.")
     (push (aget "openid.response_nonce" parameters) *nonces*)

     ;; 11.4.  Verifying Signatures
     (%check (check-signature parameters) "Invalid signature")

                   (when (aget "invalidate_handle" reply)
                     (gc-associations (aget "invalidate_handle" reply)))
                   (string= "true" (aget "is_valid" reply))))
             "Invalid signature")

     (unless v1-compat               ; Check list of signed parameters
       (let ((signed (split-sequence #\, (aget "openid.signed" parameters))))
         (every #'(lambda (f)
                    (member f signed :test #'string=))
                (cons '("op_endpoint" "return_to" "response_nonce" "assoc_handle")
                      (when (aget "openid.claimed_id" parameters)
                        '("openid.claimed_id" "openid.identity"))))))
