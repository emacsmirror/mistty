;;; oterm.el --- One Terminal -*- lexical-binding: t -*-

;; Copyright (C) 2023 Stephane Zermatten

;; Author: Stephane Zermatten <szermatt@gmx.net>
;; Version: 0.1
;; Package-Requires: ((emacs "28.2"))
;; Keywords: convenience, unix
;; URL: http://github.com/szermatt/mixterm


;;; Commentary:
;; 

(require 'term)
(require 'subr-x)
(require 'text-property-search)

;;; Code:

(defvar-local oterm-work-buffer nil)
(defvar-local oterm-term-buffer nil)
(defvar-local oterm-term-proc nil)
(defvar-local oterm-sync-marker nil)
(defvar-local oterm-cmd-start-marker nil)
(defvar-local oterm-sync-ov nil)
(defvar-local oterm-bracketed-paste nil)
(defvar-local oterm--old-point nil)
(defvar-local oterm--inhibit-sync nil)
(defvar-local oterm--deleted-point-max nil)

(defconst oterm-left-str "\eOD")
(defconst oterm-right-str "\eOC")
(defconst oterm-bracketed-paste-start-str "\e[200~")
(defconst oterm-bracketed-paste-end-str "\e[201~")

(defface oterm-debug-face
  nil ;;'((t (:box (:line-width (2 . 2) :color "cyan" :style released-button))))
  "Face used to highlight `oterm-sync-ov' for debugging.")

(defface oterm-debug-prompt-face '((t (:background "cyan")))
  "Face used to highlight prompts for debugging.")

(defvar oterm-mode-map
  (let ((oterm-mode-map (make-sparse-keymap)))
    (define-key oterm-mode-map (kbd "C-c C-c") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-z") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-\\") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-p") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-n") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-r") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-s") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-g") 'oterm-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-a") 'oterm-goto-pmark-and-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-e") 'oterm-goto-pmark-and-send-raw-key)
    (define-key oterm-mode-map (kbd "C-c C-n") 'oterm-next-prompt)
    (define-key oterm-mode-map (kbd "C-c C-p") 'oterm-previous-prompt)
    oterm-mode-map))

(defvar oterm-prompt-map
  (let ((oterm-prompt-map (make-sparse-keymap)))
    (define-key oterm-prompt-map (kbd "RET") 'oterm-send-command)
    (define-key oterm-prompt-map [S-return] 'newline)
    (define-key oterm-prompt-map (kbd "TAB") 'oterm-send-tab)
    (define-key oterm-prompt-map (kbd "DEL") 'oterm-send-backspace)
    (define-key oterm-prompt-map (kbd "C-d") 'oterm-delchar-or-maybe-eof)
    (define-key oterm-prompt-map [remap self-insert-command] 'oterm-self-insert-command )
    oterm-prompt-map))

(define-derived-mode oterm-mode fundamental-mode "One Term" "Major mode for One Term."
  (let ((work-buffer (current-buffer))
        (term-buffer (generate-new-buffer (concat " oterm tty " (buffer-name)) 'inhibit-buffer-hooks)))
    (setq oterm-work-buffer work-buffer)
    (setq oterm-term-buffer term-buffer)
    (setq oterm-sync-marker (copy-marker (point-min)))
    (setq oterm-cmd-start-marker (copy-marker (point-min)))
    (setq oterm-sync-ov (make-overlay (point-min) (point-max) nil nil 'rear-advance))
    (overlay-put oterm-sync-ov 'face 'oterm-debug-face)
    (overlay-put oterm-sync-ov 'keymap oterm-prompt-map)
    (overlay-put oterm-sync-ov 'modification-hooks (list #'oterm--modification-hook))
    (overlay-put oterm-sync-ov 'insert-behind-hooks (list #'oterm--modification-hook))
    (with-current-buffer term-buffer
      (term-mode)
      (setq oterm-work-buffer work-buffer)
      (setq oterm-term-buffer term-buffer)
      (setq oterm-sync-marker (copy-marker (point-min)))
      (setq-local term-char-mode-buffer-read-only t
                  term-char-mode-point-at-process-mark t
                  term-buffer-maximum-size 0
                  term-height 1024
                  term-width (or (window-max-chars-per-line) 80))
      (term--reset-scroll-region))
    (add-hook 'kill-buffer-hook #'oterm--kill-term-buffer nil t)
    (add-hook 'window-size-change-functions #'oterm--window-size-change nil t)
    ))

(defmacro oterm--with-live-buffer (buf &rest body)
  (declare (indent 1))
  (let ((tempvar (make-symbol "buf")))
    `(let ((,tempvar ,buf))
       (when (buffer-live-p ,tempvar)
         (with-current-buffer ,tempvar
           ,@body)))))
    
(defun oterm--kill-term-buffer ()
  (kill-buffer oterm-term-buffer))

(defun oterm--exec (program &rest args)
  (oterm-mode)
  (with-current-buffer oterm-term-buffer
    (term-exec oterm-term-buffer (buffer-name oterm-term-buffer) program nil args)
    (term-char-mode))
  (let ((proc (get-buffer-process oterm-term-buffer)))
    (with-current-buffer oterm-term-buffer
      (setq oterm-term-proc proc)
      (process-put proc 'oterm-work-buffer oterm-work-buffer)
      (process-put proc 'oterm-term-buffer oterm-term-buffer)
      (set-process-filter proc #'oterm-process-filter)
      (set-process-sentinel proc #'oterm-process-sentinel))
    (with-current-buffer oterm-work-buffer
      (setq oterm-term-proc proc)
      (add-hook 'pre-command-hook #'oterm-pre-command nil t)
      (add-hook 'post-command-hook #'oterm-post-command nil t))))

(defsubst oterm--buffer-p (buffer)
  "Return the BUFFER if the buffer is a live oterm buffer."
  (if (and buffer
           (bufferp buffer)
           (eq 'oterm-mode (buffer-local-value 'major-mode buffer))
           (buffer-live-p buffer)
           (buffer-local-value 'oterm-term-proc buffer)
           (process-live-p (buffer-local-value 'oterm-term-proc buffer)))
      buffer))

(defun oterm--buffers ()
  "List of live term buffers, sorted."
  (sort (delq nil (mapcar #'oterm--buffer-p (buffer-list)))
        (lambda (a b) (string< (buffer-name a) (buffer-name b)))))

(defun oterm ()
  (interactive)
  (let ((existing (oterm--buffers)))
    (if (or current-prefix-arg         ; command prefix was given
            (null existing)            ; there are no oterm buffers
            (and (null (cdr existing)) ; the current buffer is the only oterm buffer
                 (eq (current-buffer) (car existing))))
        ;; create a new one
        (oterm-create)
      (oterm--goto-next existing))))

(defun oterm--goto-next (existing)
  (let ((existing-tail (or (cdr (member (current-buffer) existing))
                           existing)))
    (if existing-tail
        (switch-to-buffer (car existing-tail))
      (error "no next oterm buffer"))))

(defun oterm-create ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*oterm*")
    (oterm--exec (or explicit-shell-file-name shell-file-name (getenv "ESHELL")))
    (switch-to-buffer (current-buffer))
    ))

(defun oterm-process-sentinel (proc msg)
  (when (memq (process-status proc) '(signal exit))
    (let ((work-buffer (process-get proc 'oterm-work-buffer))
          (term-buffer (process-get proc 'oterm-term-buffer)))
      (if (buffer-live-p work-buffer)
          (progn
            (while (accept-process-output proc 0 0 t))
            (term-sentinel proc msg)
            (with-current-buffer work-buffer
              (oterm--term-to-work))
            (kill-buffer term-buffer))
        (term-sentinel proc msg)))))

(defun oterm-process-filter (proc str)
  (let ((old-pmark (marker-position (process-mark proc)))
        (work-buffer (process-get proc 'oterm-work-buffer))
        (term-buffer (process-get proc 'oterm-term-buffer))
        (bracketed-paste-turned-on nil)
        (inhibit-modification-hooks t))
    (setq bracketed-paste-turned-on (oterm-emulate-terminal proc str))
    (oterm--with-live-buffer term-buffer
      (goto-char (process-mark proc)))
    (oterm--with-live-buffer work-buffer
      (when (buffer-live-p term-buffer)
        (setq default-directory (buffer-local-value 'default-directory term-buffer))
        (unless oterm--inhibit-sync
          (let ((point-on-pmark (equal (point) (oterm--from-pos-of old-pmark oterm-term-buffer))))
            (oterm--term-to-work)
            (when bracketed-paste-turned-on
              (oterm--move-sync-mark (oterm-pmark) 'set-prompt))
            (when (and (/= old-pmark (marker-position (process-mark proc)))
                       point-on-pmark)
              (goto-char (oterm-pmark)))))))))

(defun oterm-emulate-terminal (proc str)
  "Handle special terminal codes, then call `term-emlate-terminal'.

This functions intercepts some extented sequences term.el. This
all should rightly be part of term.el."
  (let ((start 0)
        (bracketed-paste-turned-on nil)
        found)
    (while (setq found (string-match "\e\\[\\(\\?2004[hl]\\)" str start))
      (let ((ext (match-string 1 str))
            (next (match-end 0)))
        (term-emulate-terminal proc (substring str start next))
        (oterm--with-live-buffer (process-get proc 'oterm-work-buffer)
          (cond
           ((equal ext "?2004h")
            (setq oterm-bracketed-paste t
                  bracketed-paste-turned-on t))
           ((equal ext "?2004l")
            (setq oterm-bracketed-paste nil))))
        (setq start next)))
    (let ((final-str (substring str start)))
      (unless (zerop (length final-str))
        (term-emulate-terminal proc final-str)))
    bracketed-paste-turned-on))

(defun oterm--maybe-bracketed-str (str)
  (when (string-match "\t" str)
    (setq str (replace-string "\t" (make-string tab-width " "))))
  (cond
   ((not oterm-bracketed-paste) str)
   ((not (string-match "[[:cntrl:]]" str)) str)
   (t (concat oterm-bracketed-paste-start-str
              str
              oterm-bracketed-paste-end-str
              oterm-left-str
              oterm-right-str))))

(defun oterm-pmark ()
  "The terminal process mark as a position within the current buffer (work or term)."
  (oterm--from-pos-of (process-mark oterm-term-proc) oterm-term-buffer))

(defun oterm--from-pos-of (pos buffer-of-pos)
  "Return the local equivalent to POS defined in BUFFER-OF-POS."
  (+ oterm-sync-marker (with-current-buffer buffer-of-pos
                         (- pos oterm-sync-marker))))

(defun oterm--term-to-work ()
  (let ((inhibit-modification-hooks t))
    (with-current-buffer oterm-term-buffer
      (save-restriction
        (narrow-to-region oterm-sync-marker (point-max-marker))
        (with-current-buffer oterm-work-buffer
          (let ((saved-undo buffer-undo-list))
            (save-excursion
              (save-restriction
                (narrow-to-region oterm-sync-marker (point-max-marker))
                (let ((inhibit-modification-hooks t))
                  ;; Clear text properties that might have been set by
                  ;; the tty in a previous call.
                  (when (< oterm-cmd-start-marker (point-max))
                    (set-text-properties oterm-cmd-start-marker (point-max) nil))
                  (condition-case nil
                      (replace-buffer-contents oterm-term-buffer)
                    (text-read-only
                     ;; Replace-buffer-contents attempted to modify the prompt.
                     ;; Remove it and try again.
                     (let ((inhibit-read-only t))
                       (set-text-properties (point-min) (point-max) nil)
                       (move-marker oterm-cmd-start-marker oterm-sync-marker)
                       (replace-buffer-contents oterm-term-buffer)))))))
            (setq buffer-undo-list saved-undo)))))
    
    ;; Next time, only sync the visible portion of the terminal.
    (with-current-buffer oterm-term-buffer
      (when (< oterm-sync-marker term-home-marker)
        (oterm--move-sync-mark term-home-marker)))

    ;; Truncate the term buffer, since scrolling back is available on
    ;; the work buffer anyways. This has to be done now, after syncing
    ;; the marker, and not in term-emulate-terminal, which is why
    ;; term-buffer-maximum-size is set to 0.
    (with-current-buffer oterm-term-buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char term-home-marker)
          (forward-line -5)
          (delete-region (point-min) (point)))))

    ))

(defun oterm--move-sync-mark (pos &optional set-prompt)
  (let ((chars-from-bol (- pos (oterm--bol-pos-from pos)))
        (chars-from-end (- (point-max) (oterm--bol-pos-from pos))))
    (with-current-buffer oterm-term-buffer
      (move-marker oterm-sync-marker (- (point-max) chars-from-end)))
    (with-current-buffer oterm-work-buffer
      (when (> oterm-cmd-start-marker oterm-sync-marker)
        (let ((inhibit-read-only t))
          (remove-text-properties oterm-sync-marker oterm-cmd-start-marker '(read-only t))))
      (let* ((sync-pos (- (point-max) chars-from-end))
             (cmd-start-pos (+ sync-pos chars-from-bol)))
        (move-marker oterm-sync-marker sync-pos)
        (move-marker oterm-cmd-start-marker cmd-start-pos)
        (move-overlay oterm-sync-ov sync-pos (point-max))
        (when (and set-prompt (> cmd-start-pos sync-pos))
          (add-text-properties sync-pos cmd-start-pos
                               '(oterm prompt
                                       field 'oterm-prompt
                                       rear-nonsticky t
                                       face oterm-debug-prompt-face))
          (add-text-properties sync-pos cmd-start-pos
                               '(read-only t front-sticky t)))))))

(defun oterm-send-raw-string (str)
  (when (and str (not (zerop (length str))))
    (with-current-buffer oterm-term-buffer
      (term-send-raw-string str))))

(defun oterm--at-prompt-1 (&optional inexact)
  (let ((pmark (oterm-pmark)))
    (if inexact
        (or (>= (point) pmark)
            (>= (oterm--bol-pos-from (point))
                (oterm--bol-pos-from pmark)))
        (= (point) pmark))))

(defun oterm--bol-pos-from (pos)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-beginning-position))))

(defun oterm--eol-pos-from (pos)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-end-position))))

(defun oterm-send-command ()
  "Send the current command to the shell."
  (interactive)
  (goto-char (oterm-pmark))
  (oterm-send-raw-string "\n"))

(defun oterm-send-tab ()
  "Send TAB to the shell."
  (interactive)
  (oterm-send-raw-string "\t"))

(defun oterm-send-backspace ()
  "Send DEL to the shell."
  (interactive)
  (when (get-pos-property (point) 'read-only)
    (signal 'text-read-only nil))
  (oterm-send-raw-string "\b"))

(defun oterm-self-insert-command (n &optional c)
  (interactive "p")
  (when (get-pos-property (point) 'read-only)
    (signal 'text-read-only nil))
  (let ((keys (this-command-keys)))
    (oterm-send-raw-string (make-string n (aref keys (1- (length keys)))))))

(defun oterm-send-raw-key ()
  (interactive)
  (let ((keys (this-command-keys)))
    (oterm-send-raw-string (make-string 1 (aref keys (1- (length keys)))))))

(defun oterm-goto-pmark-and-send-raw-key ()
  (interactive)
  (goto-char (oterm-pmark))
  (let ((keys (this-command-keys)))
    (oterm-send-raw-string (make-string 1 (aref keys (1- (length keys)))))))

(defun oterm-delchar-or-maybe-eof (arg)
  (interactive "p")
  (if (zerop (length (replace-regexp-in-string "[[:blank:]]*" (buffer-substring-no-properties oterm-sync-marker (oterm--eol-pos-from oterm-sync-marker)) "")))
      (oterm-send-raw-string (kbd "C-d"))
    (delete-char arg)))

(defun oterm--modification-hook (_ov is-after orig-beg orig-end &optional old-length)
  (when (and (buffer-live-p oterm-term-buffer)
             is-after
             (>= orig-end oterm-cmd-start-marker))
    ;; Attempt to replay the change in the terminal.
    (let ((inhibit-read-only t)
          (pmark (oterm-pmark))
          (initial-point (point))
          (beg (max orig-beg oterm-cmd-start-marker))
          (end (max orig-end oterm-cmd-start-marker))
          (old-end (max (+ orig-beg old-length) oterm-cmd-start-marker)))
      (add-text-properties beg end '(oterm-inserted t))
      (remove-text-properties beg end '(oterm-shift nil))
      (let ((pos end)
            (shift (- old-end end)))
        ;; TODO: optimize
        (while (< pos (point-max))
          (unless (get-text-property pos 'oterm-inserted)
            (put-text-property pos (1+ pos) 'oterm-shift (+ (or (get-text-property pos 'oterm-shift) 0) shift)))
          (setq pos (1+ pos))))
      (when (> old-end (point-max))
        (setq oterm--deleted-point-max t)))))

(defun oterm--collect-modifications ()
  (save-restriction
    (narrow-to-region oterm-sync-marker (point-max))
    (let ((current-shift 0)
          last-noninsert
          changes)
      (save-excursion
        (goto-char (point-min))
        (while (< (point) (point-max))
          (if (get-text-property (point) 'oterm-inserted)
              (progn
                (let ((change-start (+ (point) current-shift))
                      delete-end)
                  (goto-char (or (next-single-property-change (point) 'oterm-inserted) (point-max)))
                  (if (< (point) (point-max))
                      (let ((shift (or (get-text-property (point) 'oterm-shift) 0)))
                        (setq old-length (- (+ (point) shift) change-start))
                        (setq current-shift shift))
                    (if (not oterm--deleted-point-max)
                        (setq old-length 0)
                      (setq old-length -1
                            oterm--deleted-point-max nil))
                  (push (list change-start
                              (buffer-substring-no-properties change-start (point))
                              old-length)
                        changes))))
            (setq last-noninsert (+ (point) (or (get-text-property (point) 'oterm-shift) 0)))
            (let ((shift (or (get-text-property (point) 'oterm-shift) 0)))
              (when (> shift current-shift)
                (push (list (+ (point) current-shift) "" (- shift current-shift)) changes)
                (setq current-shift shift)))
            (goto-char (1+ (point))))))
      (when (and oterm--deleted-point-max (or (null changes) (/= -1 (nth 2 (car changes)))))
        (push (list (or (1+ last-noninsert) (point-min)) "" -1) changes))
      (setq oterm--deleted-point-max nil)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (remove-text-properties (point-min) (point-max) '(oterm-inserted oterm-shift oterm-end)))
      (nreverse changes))))

(defun oterm--replay-modification (orig-beg content old-length)
  (let* ((pmark (oterm-pmark))
         (initial-point (point))
         (beg orig-beg)
         (end (+ orig-beg (length content)))
         (old-end (if (> old-length 0) (+ orig-beg old-length) (oterm--from-pos-of
                                                                (with-current-buffer oterm-term-buffer (point-max))
                                                                oterm-term-buffer))))
    (when (> end beg)
      (oterm--send-and-wait (oterm--move-str pmark beg))
      (setq pmark (oterm-pmark))
      ;; pmark is as close to beg as we can make it
      
      ;; We couldn't move pmark as far back as beg. Presumably, the
      ;; process mark points to the leftmost modifiable position of
      ;; the command line. Update the sync marker to start sync there
      ;; from now on and avoid getting this hook called unnecessarily.
      ;; This is done from inside the term buffer as the modifications
      ;; of the work buffer could interfere. TODO: What if the process
      ;; is just not accepting any input at this time? We might move
      ;; sync mark to far down.
      (when (> (oterm--distance-on-term beg pmark) 0)
        (oterm--move-sync-mark pmark 'set-prompt))
      
      (setq beg (max beg pmark)))
    
    (when (> old-end beg)
      (oterm--send-and-wait (oterm--move-str pmark old-end))
      (setq pmark (oterm-pmark))
      (setq old-end (max beg (min old-end pmark))))
    
    ;; Replay the portion of the change that we think we can
    ;; replay.
    (oterm--send-and-wait
     (concat
      (when (> old-end beg)
        (oterm--repeat-string (oterm--distance-on-term beg old-end) "\b"))
      (when (> end beg)
        (oterm--maybe-bracketed-str (substring content (max 0 (- beg orig-beg)) (min (length content) (max 0 (- end orig-beg)))))))))
  )

(defun oterm--send-and-wait (str)
  (when (and str (not (zerop (length str))))
    (let ((oterm--inhibit-sync t))
      (oterm-send-raw-string str)
      (when (accept-process-output oterm-term-proc 1 nil t) ;; TODO: tune the timeout
        (while (accept-process-output oterm-term-proc 0 nil t))))))

(defun oterm--move-str (from to)
  (let ((diff (oterm--distance-on-term from to)))
    (if (zerop diff)
        nil
      (oterm--repeat-string
       (abs diff)
       (if (< diff 0) oterm-left-str oterm-right-str)))))


(defun oterm--distance-on-term (beg end)
  "Compute the number of cursor moves necessary to get from BEG to END.

This function skips over the `term-line-wrap' newlines introduced by term as if they were not here.

While it takes BEG and END as work buffer positions, it looks in
the term buffer to figure out, so it's important for the BEG and
END section to be valid in the term buffer."
  (with-current-buffer oterm-term-buffer
    (let ((beg (oterm--from-pos-of (min beg end) oterm-work-buffer))
          (end (oterm--from-pos-of (max beg end) oterm-work-buffer))
          (sign (if (< end beg) -1 1)))
      (let ((pos beg) (nlcount 0))
        (while (and (< pos end) (setq pos (text-property-any pos end 'term-line-wrap t)))
          (setq pos (1+ pos))
          (setq nlcount (1+ nlcount)))
        (* sign (- (- end beg) nlcount))))))

(defun oterm--repeat-string (count elt)
  (let ((elt-len (length elt)))
    (if (= 1 elt-len)
        (make-string count (aref elt 0))
      (let ((str (make-string (* count elt-len) ?\ )))
        (dotimes (i count)
          (dotimes (j elt-len)
            (aset str (+ (* i elt-len) j) (aref elt j))))
        str))))

(defun oterm-next-prompt (n)
  (interactive "p")
  (let (found)
    (dotimes (_ n)
      (if (setq found (text-property-any (point) (point-max) 'oterm 'prompt))
          (goto-char (or (next-single-property-change found 'oterm) (point-max)))
        (error "No next prompt")))))

(defun oterm-previous-prompt (n)
  (interactive "p")
  (dotimes (_ n)
    (unless (text-property-search-backward 'oterm 'prompt)
      (error "No previous prompt"))))

(defun oterm-pre-command ()
  (setq oterm--old-point (point)
        oterm--inhibit-sync t))

(defun oterm-post-command ()
  (setq oterm--inhibit-sync nil)
  (run-at-time 0 nil #'oterm-post-command-1 oterm-work-buffer))

(defun oterm-post-command-1 (buf)
  (oterm--with-live-buffer buf
    (save-excursion
      (let ((changes (oterm--collect-modifications)))
        (dolist (c changes)
          (apply #'oterm--replay-modification c)
          (oterm--term-to-work))))
    (when (and oterm--old-point
               (/= (point) oterm--old-point)
               (markerp oterm-sync-marker)
               (>= (point) oterm-sync-marker)
               (process-live-p oterm-term-proc)
               (buffer-live-p oterm-term-buffer)
               oterm-bracketed-paste)
      (oterm-send-raw-string (oterm--move-str (oterm-pmark) (point))))))

(defun oterm--window-size-change (_win)
  (when (process-live-p oterm-term-proc)
    (let* ((adjust-func (or (process-get oterm-term-proc 'adjust-window-size-function)
                            window-adjust-process-window-size-function))
           (width (car (funcall adjust-func oterm-term-proc (get-buffer-window-list)))))
      (oterm--set-process-window-width (or width 132)))))

(defun oterm--set-process-window-width (width)
  (oterm--with-live-buffer oterm-term-buffer
    (set-process-window-size oterm-term-proc term-height width)
    (term-reset-size term-height width)))

(provide 'oterm)

;;; oterm.el ends here
