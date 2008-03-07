(in-package #:tpd2.io)

(deftype sendbuf-small-integer ()
  '(unsigned-byte 24))

(defstruct sendbuf
  (head nil :type list)
  (tail nil :type list)
  (num-bufs 0 :type sendbuf-small-integer)
  (len 0 :type sendbuf-small-integer))

(my-defun sendbuf add (x)
  (my-declare-fast-inline)
  (cond ((sendbuf-p x)
	 (my merge x))
	(x
	 (let ((buf (force-byte-vector x)))
	   (unless (zerop (length buf))
	     (incf (my num-bufs))
	     (incf (my len) (the sendbuf-small-integer (length buf)))
	     (let ((n (cons buf nil)))
	       (cond ((my head)
		      (setf (cdr (my tail)) n)
		      (setf (my tail) n))
		     (t (setf (my head) n
			      (my tail) n))))))))
  (values))

(my-defun sendbuf merge (other)
  (my-declare-fast-inline)
  (cond 
    ((my head)
     (setf (cdr (my tail)) (sendbuf-head other))
     (when (sendbuf-tail other)
       (setf (my tail) (sendbuf-tail other))))
    (t (setf (my head) (sendbuf-head other)
	     (my tail) (sendbuf-tail other))))

  (incf (my len) (sendbuf-len other))
  (incf (my num-bufs) (sendbuf-num-bufs other))
  (setf (sendbuf-num-bufs other) 0 
	 (sendbuf-head other) nil
	 (sendbuf-tail other) nil
	 (sendbuf-len other) 0)
  (values))

(defmacro with-sendbuf-continue ((var) &body body &environment env)
  `(progn
     ,@(loop for form in (merge-constant-arguments body :join 'byte-vector-cat :env env)
	     collect 
	     `(sendbuf-add ,var
			   ,form))
     (values)))

(defmacro with-sendbuf ((&optional (var (gensym "sendbuf"))) &body body)
  (check-symbols var)
  `(let ((,var (make-sendbuf)))
     (with-sendbuf-continue (,var)
       ,@body)
     ,var))

(my-defun sendbuf done ()
  (not (my head)))

(my-defun sendbuf send-write (con done)
  (declare (optimize speed))
  (loop for buf = (car (my head))
	while 		   
	(let ((s (socket-write (con-socket con) buf)))
	  (when s
	    (cond ((> (length buf) s)
		   (setf (car (my head)) (make-displaced-vector buf :start s))
		   nil)
		  (t
		   (setf (my head) (cdr (my head)))
		   (decf (my num-bufs))
		   (my head))))))
  (if (my head)
    (con-when-ready-to-write con #'my-call)
    (funcall done)))


(my-defun sendbuf send-writev (con done)
  (declare (optimize speed))
  (when (my head)
    (let ((count (min +max-iovecs+ (my num-bufs))))
      (cffi:with-foreign-object (vecs 'iovec count)
	(loop for i below count
	      for buf in (my head)
	      do 
	      (with-pointer-to-vector-data (ptr buf)
		(cffi:with-foreign-slots ((base len) (cffi:mem-aref vecs 'iovec i) iovec)
		  (setf base ptr)
		  (setf len (length buf)))))
	(let ((s (socket-writev (con-socket con) vecs count)))
	  (when s
	    (loop until (zerop s)
		  do
		  (let ((buf (car (my head))))
		    (cond ((>= s (length buf))
			   (decf s (length buf))
			   (setf (my head) 
				 (cdr (my head))))
			  (t
			   (setf (car (my head)) (make-displaced-vector buf :start s))
			   (setf s 0))))))))))
  (if (my head)
      (con-when-ready-to-write con #'my-call)
      (funcall done)))


(my-defun sendbuf to-byte-vector ()
  (declare (optimize speed))
  (let ((result (make-byte-vector (my len))) (i 0))
    (loop for s in (my head) do
	  (loop for c across (the simple-byte-vector s) do
		(setf (aref result i) c)
		(incf i)))
    result))

(my-defun sendbuf 'print-object (stream)
  (cond (*print-readably* (call-next-method))
	(t (write (force-string (my to-byte-vector)) :stream stream))))

(my-defun sendbuf empty ()
  (not (my head)))
