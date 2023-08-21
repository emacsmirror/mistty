;;; mistty-util.el --- random utils used by mistty -*- lexical-binding: t -*-

(defvar mistty--last-id 0
  "The last ID generated by `mistty--next-id'.

This variable is used to generate a new number every time
`mistty-next-id' is called. It is not meant to be accessed or
changed outside of this function.")

(defmacro mistty--with-live-buffer (buf &rest body)
  (declare (indent 1))
  (let ((tempvar (make-symbol "buf")))
    `(let ((,tempvar ,buf))
       (when (buffer-live-p ,tempvar)
         (with-current-buffer ,tempvar
           ,@body)))))

(defun mistty--next-id ()
  (setq mistty--last-id (1+ mistty--last-id)))

(defun mistty--bol-pos-from (pos &optional n)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-beginning-position n))))

(defun mistty--eol-pos-from (pos)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-end-position))))

(defun mistty--bol-skipping-fakes (pos)
  (save-excursion
    (let ((inhibit-field-text-motion t))
      (goto-char pos)
      (while (and (setq pos (line-beginning-position))
                  (eq ?\n (char-before pos))
                  (get-text-property (1- pos) 'term-line-wrap))
        (goto-char (1- pos)))
      pos)))

(defun mistty--repeat-string (count elt)
  (let ((elt-len (length elt)))
    (if (= 1 elt-len)
        (make-string count (aref elt 0))
      (let ((str (make-string (* count elt-len) ?\ )))
        (dotimes (i count)
          (dotimes (j elt-len)
            (aset str (+ (* i elt-len) j) (aref elt j))))
        str))))

(defun mistty--safe-bufstring (start end)
  (let ((start (max (point-min) (min (point-max) start)))
        (end (max (point-min) (min (point-max) end))))
    (if (> end start)
        (buffer-substring-no-properties start end)
      "")))

(defun mistty--safe-pos (pos)
  (min (point-max) (max (point-min) pos)))

(defun mistty--lines ()
  "A list of markers to the beginning of the buffer's line."
  (save-excursion
    (goto-char (point-min))
    (let ((lines (list (point-min-marker))))
      (while (search-forward "\n" nil t)
        (push (point-marker) lines))
      (nreverse lines))))

(defun mistty--col (pos)
  "Column number at POS"
  (- pos (mistty--bol-pos-from pos)))

(defun mistty--line (pos)
  "Line number at POS"
  (save-excursion
    (let ((count 0))
      (goto-char pos)
      (while (zerop (forward-line -1))
        (setq count (1+ count)))
      count)))

(defun mistty--line-length (pos)
  "Length of the line at POS"
  (- (mistty--eol-pos-from pos)
     (mistty--bol-pos-from pos)))

(provide 'mistty-util)
