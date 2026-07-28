;;; mistty-direct.el --- Raw alacritty-based terminal -*- lexical-binding: t -*-

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; `http://www.gnu.org/licenses/'.

;;; Commentary:
;;
;; This file defines a mode that provides direct access to
;; alacritty-based terminal, with none of the extra features
;; and overhead of MisTTY. The result is similar to term.el
;; in raw mode.

(require 'mistty-mod)
(require 'mistty-util)
(defvar explicit-shell-file-name) ;; defined in shell

(defvar-local mistty-direct--vterm nil
  "Virtual terminal tied to the buffer, from mistty-mod.")

(defvar-local mistty-direct--cursor nil
  "Marker that tracks the cursor position, set by the last rendering
operation.")

(defvar-keymap mistty-direct-mode-map
  :doc "Keymap of major mode MisTTY Direct"
  "RET" #'mistty-direct-send-self
  "TAB" #'mistty-direct-send-self
  "DEL" #'mistty-direct-send-self
  "C-d" #'mistty-direct-send-self
  "C-a" #'mistty-direct-send-self
  "C-e" #'mistty-direct-send-self
  "C-p" #'mistty-direct-send-self
  "C-n" #'mistty-direct-send-self
  "C-k" #'mistty-direct-send-self
  "C-w" #'mistty-direct-send-self
  "<remap> <self-insert-command>" #'mistty-direct-send-self)

(define-derived-mode mistty-direct-mode fundamental-mode "MisTTY Direct"
  "Major mode that provides a raw terminal tied to a subprocess.

Call `mistty-direct-exec' to create the virtual terminal and start the
process."
  (use-local-map mistty-direct-mode-map))

(defun mistty-direct-exec (name program args)
  (unless (eq major-mode 'mistty-direct-mode)
    (error "Must be called from a mistty-direct-mode buffer."))
  (when (get-buffer-process (current-buffer))
    (error "A process is already attached to the buffer."))
  (message "launch %s" program)
  (let ((process-environment
         (list "TERM=xterm-256color"
               (concat "INSIDE_EMACS=" emacs-version)))
        (process-connection-type t)
	;; We should suppress conversion of end-of-line format.
	(inhibit-eol-conversion t)
	;; The process's output contains not just chars but also binary
	;; escape codes, so we need to see the raw output.  We will have to
	;; do the decoding by hand on the parts that are made of chars.
	(coding-system-for-read 'binary))
    (setq mistty-direct--cursor (make-marker))
    (setq mistty-direct--vterm (mistty-mod-make-vterm 80 24))
    (let ((proc (apply #'start-file-process name (current-buffer)
                       ;; On Android, /bin doesn't exist, and the default shell is
                       ;; found as /system/bin/sh.
	               (if (eq system-type 'android)
                           "/system/bin/sh"
                         "/bin/sh")
                       "-c"
	               (format "stty -nl echo rows %d columns %d sane 2>%s;\
if [ $1 = .. ]; then shift; fi; exec \"$@\""
                               ;; term-height term-width null-device
		               24 80 "/dev/null")
	               ".."
	               program args)))
      ;; start-file-process doesn't always respect
      ;; coding-system-for-read. Force it.
      (set-process-coding-system proc 'binary (cdr (process-coding-system proc)))
      (mistty-mod-render mistty-direct--vterm (point-min) (point-max) mistty-direct--cursor)
      (set-process-filter proc #'mistty-direct--process-filter)
      (set-process-sentinel proc #'mistty-direct--sentinel))))

(defun mistty-direct--process-filter (proc str)
  (mistty--with-live-buffer (process-buffer proc)
    (when-let* ((vterm mistty-direct--vterm))
      (dolist (ev (mistty-mod-process-bytes vterm (vconcat str)))
        (pcase ev
          (`(pty-write ,data)
           (process-send-string proc data))))
      (mistty-mod-render-damaged vterm (point-min) (point-max) mistty-direct--cursor)
      (goto-char mistty-direct--cursor))))

(defun mistty-direct--sentinel (proc _msg)
  (when (memq (process-status proc) '(signal exit))
    (mistty--with-live-buffer (process-buffer proc)
      (setq mistty-direct--vterm nil))
    (set-process-buffer proc nil)
    (delete-process proc)))

(defun mistty-direct-launch ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*mistty-direct*")
    (mistty-direct-mode)
    (mistty-direct-exec
     (buffer-name)
     (with-connection-local-variables
      (or
       explicit-shell-file-name
       shell-file-name
       (getenv "SHELL")))
     '("-i"))
    (pop-to-buffer (current-buffer))))

(defun mistty-direct-send-self (&optional n key)
  (interactive "p")
  (if-let ((proc (get-buffer-process (current-buffer))))
      (let* ((key (or key (this-command-keys-vector)))
             (translated-key (mistty-translate-key key n)))
        (message "SEND %S" translated-key)
        (process-send-string proc translated-key))
    (message "NO PROCESS")
    (self-insert-command n key)))

(provide 'mistty-direct)

;;; mistty-direct.el ends here
