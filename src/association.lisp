(in-package #:cl-openid)

(defconstant +dh-prime+
  (parse-integer (concatenate 'string
                              "DCF93A0B883972EC0E19989AC5A2CE310E1D37717E8D9571BB7623731866E61E"
                              "F75A2E27898B057F9891C2E27A639C3F29B60814581CD3B2CA3986D268370557"
                              "7D45C2E7E52DC81C7A171876E5CEA74B1448BFDFAF18828EFD2519F14E45E382"
                              "6634AF1949E5B535CC829A483B8A76223E5D490A257F05BDFF16F2FB22C583AB")
                 :radix 16)
  "This is a confirmed-prime number, used as the default modulus for Diffie-Hellman Key Exchange.

OpenID Authentication 2.0 Appendix B.  Diffie-Hellman Key Exchange Default Value")

(defconstant +dh-generator+ 2)

;; An association.  Endpoint URI is the hashtable key.
(defstruct (association
             (:constructor %make-association))
  (expires nil :type integer)
  (handle nil :type string)
  (mac nil :type (simple-array (unsigned-byte 8) (*)))
  (hmac-digest nil :type keyword))

(defvar *associations* (make-hash-table))

(defun aget (k a)
  (cdr (typecase k
         (sequence (assoc k a :test #'equal))
         (t (assoc k a)))))

(defun btwoc (i &aux (octets (integer-to-octets i)))
  (if (or (zerop (length octets))
          (> (aref octets 0) 127))
      (concatenate '(simple-array (unsigned-byte 8) (*)) '(0) octets)
      octets))

(defun base64-btwoc (i)
  (usb8-array-to-base64-string (btwoc i)))

(defun parse-kv (array)
  "Parse key-value form message passed as an (unsigned-byte 8) array into alist.

OpenID Authentication 2.0 4.1.1.  Key-Value Form Encoding."
  (loop
     for start = 0 then (1+ end)
     for end = (position 10 array :start start)
     for colon = (position #.(char-code #\:) array :start start)
     when colon collect
       (cons (utf-8-bytes-to-string array :start start :end colon)
             (utf-8-bytes-to-string array :start (1+ colon) :end (or end (length array))))
     while end))

(define-condition openid-request-error (error)
  ((message :initarg :message :reader message)
   (parameters :initarg :parameters :reader parameters))
  (:report (lambda (e s)
             (format s "OpenID request error: ~A" (message e)))))

(defun direct-request (uri parameters)
  (let ((*text-content-types* nil))
    (multiple-value-bind (body status-code)
        (http-request uri
                      :method :post
                      :parameters (acons "openid.ns" "http://specs.openid.net/auth/2.0"
                                         parameters))
      (let ((parameters (parse-kv body)))
        (if (= 200 status-code)
            parameters
            (error 'openid-request-error
                   :message (aget "error" parameters)
                   :parameters parameters))))))

(defvar *default-association-timeout* 3600
  "Default association timeout, in seconds")

(define-condition openid-association-error (simple-error)
  ())

(defun openid-association-error (format-control &rest format-parameters)
  (error 'openid-association-error
         :format-control format-control
         :format-parameters format-parameters))

(defun session-digest-type (session-type)
  (or (aget session-type  '(("DH-SHA1" . :SHA1)
                            ("DH-SHA256" . :SHA256)))
      (unless (member session-type '("" "no-encryption")
                      :test #'string=)
        (openid-association-error "Unknown session type ~A" session-type))))

;; FIXME:gentemp (use true random unique handle -- UUID?)
(defpackage :cl-openid.assoc-handles
  (:use)
  (:documentation "Package for generating unique association handles."))

(defun ensure-integer (val)
  (etypecase val
    (integer val)
    (string (base64-string-to-integer val))
    (vector (octets-to-integer val))))

(defun ensure-vector (val)
  (etypecase val
    (integer (btwoc val))
    (string (base64-string-to-usb8-array val))
    (vector val)))

(defun ensure-vector-length (vec len)
  (cond ((= (length vec) len) vec)
        ((> (length vec) len)
         (subseq vec (- (length vec) len)))
        (t (let ((rv (adjust-array vec len))
                 (d (- len (length vec))))
             (psetf (subseq rv d)
                    (subseq rv 0 len)

                    (subseq rv 0 d)
                    (make-array d :initial-element 0))
             rv))))


(defun dh-encrypt/decrypt-key (digest generator prime public private key)
  (let* ((k (expt-mod public private prime))
         (h (octets-to-integer (digest-sequence digest (btwoc k))))
         (mac (logxor h (ensure-integer key))))
    (values (integer-to-octets mac)
            (expt-mod generator private prime))))

(defun make-association (&key
                         (handle (string (gentemp "H" :cl-openid.assoc-handles)))
                         (expires-in *default-association-timeout*)
                         (expires-at (+ (get-universal-time) expires-in))

                         association-type
                         (hmac-digest (or (aget association-type
                                                '(("HMAC-SHA1" . :SHA1)
                                                  ("HMAC-SHA256" . :SHA256)))
                                          (openid-association-error "Unknown association type ~A." association-type)))
                         
                         (mac (random #.(expt 2 32)))) ; FIXME: random

  "Make new association structure, DWIM included.

 - HANDLE should be the new association handle; if none is provided,
   new one is generated.
 - EXPIRES-IN is the timeout of the handle; alternatively, EXPIRES-AT
   is the universal-time when association times out.
 - ASSOCIATION-TYPE is the OpenID association type (string);
   alternatively, HMAC-DIGEST is an Ironclad digest name (a keyword)
   used for signature HMAC checks.
 - MAC is the literal, unencrypted MAC key."
  (%make-association :handle handle
                     :expires expires-at
                     :mac (ensure-vector-length (ensure-vector mac)
                                                (ecase hmac-digest
                                                  (:sha1 20)
                                                  (:sha256 32)))
                     :hmac-digest hmac-digest))

(defun do-associate (endpoint
                     &key
                     v1
                     assoc-type session-type
                     &aux
                     (parameters '(("openid.mode" . "associate")))
                     xa)

  ;; optimize? move to constants?
  (let  ((supported-atypes  (if v1
                                '("HMAC-SHA1")
                                '("HMAC-SHA256" "HMAC-SHA1")))
         (supported-stypes (if v1
                               '("DH-SHA1" "")
                               (if (eq :https (uri-scheme (uri endpoint)))
                                   '("DH-SHA256" "DH-SHA1" "no-encryption")
                                   '("DH-SHA256" "DH-SHA1")))))
    (unless assoc-type
      (setf assoc-type  (first supported-atypes)))
    
    (unless session-type
      (setf session-type (first supported-stypes)))

    (hunchentoot:log-message :debug
                             "Associating~:[~; v1-compatible~] with ~A (assoc ~S, session ~S)"
                             v1 endpoint assoc-type session-type)

    (push (cons "openid.assoc_type" assoc-type) parameters)
    (push (cons "openid.session_type" session-type) parameters)

    (handler-bind ((openid-request-error
                    #'(lambda (e)
                        (when (equal (cdr (assoc "error_code" (parameters e)
                                                 :test #'string=))
                                     "unsupported-type")
                          (let ((supported-atype (aget "assoc_type" (parameters e)))
                                (supported-stype (aget "session_type" (parameters e))))
                            (return-from do-associate
                              (when (and (member supported-atype supported-atypes :test #'equal)
                                         (member supported-stype supported-stypes :test #'equal))
                                (do-associate endpoint
                                  :v1 v1
                                  :assoc-type supported-atype
                                  :session-type supported-stype))))))))

      (when (string= "DH-" session-type :end2 3) ; Diffie-Hellman
        (setf xa (random +dh-prime+)) ; FIXME: use safer prng generation
        (push (cons "openid.dh_consumer_public"
                    (base64-btwoc (expt-mod +dh-generator+ xa +dh-prime+)))
              parameters))

      (let* ((response (direct-request endpoint parameters)))
        (values
         (make-association :handle (aget "assoc_handle" response)
                           :expires-in (parse-integer (aget "expires_in" response)) 
                           :mac (or (aget "mac_key" response)
                                    (dh-encrypt/decrypt-key (session-digest-type session-type)
                                                            +dh-generator+ +dh-prime+
                                                            (base64-string-to-integer (aget "dh_server_public" response))
                                                            xa
                                                            (aget "enc_mac_key" response)))
                           :association-type assoc-type)
         endpoint)))))

(defun gc-associations (&optional invalidate-handle &aux (time (get-universal-time)))
  (maphash #'(lambda (ep association)
               (when (or (> time (association-expires association))
                         (and invalidate-handle
                              (string= invalidate-handle (association-handle association))))
                 (hunchentoot:log-message :debug "GC association with ~A ~S" ep association)
                 (remhash ep *associations*)))
           *associations*))

(defun association (endpoint &optional v1)
  (gc-associations)                     ; keep clean
  (setf endpoint (intern-uri endpoint))
  (or (gethash endpoint *associations*)
      (setf (gethash endpoint *associations*)
            (do-associate endpoint :v1 v1))))

(defun associate (id)
  (association (aget :op-endpoint-url id)
               (= 1 (car (aget :protocol-version id)))))

;;; FIXME: optimize, reduce consing
(defun kv-encode (alist)
  (string-to-utf-8-bytes
   (apply #'concatenate 'string
          (loop
             for (k . v) in alist
             collect k
             collect ":"
             collect v
             collect '(#\Newline)))))

(defun sign (association parameters &optional signed)
  (unless signed
    (setf signed (split-sequence #\, (aget "openid.signed" parameters))))

  (usb8-array-to-base64-string
   (hmac-digest
    (update-hmac (make-hmac (association-mac association)
                            (association-hmac-digest association))
                 (kv-encode (loop
                               for field in signed
                               collect (cons field
                                             (aget (concatenate 'string "openid." field)
                                                   parameters))))))))

(defun association-by-handle (handle)
  (maphash #'(lambda (ep assoc)
               (declare (ignore ep))
               (when (string= handle (association-handle assoc))
                 (return-from association-by-handle assoc)))
           *associations*))

(defun check-signature (parameters &optional (association (association-by-handle (aget "openid.assoc_handle" parameters))))
  (string= (sign association parameters)
           (aget "openid.sig" parameters)))
