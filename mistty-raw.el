;;; mistty-raw.el --- Raw alacritty-based terminal -*- lexical-binding: t -*-

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
(require 'mistty-kbd)
(require 'mistty-log)

(defvar explicit-shell-file-name) ;; defined in shell

(defvar-local mistty-raw--vterm nil
  "Virtual terminal tied to the buffer, from mistty-mod.")

(defvar-local mistty-raw--cursor nil
  "Marker that tracks the cursor position, set by the last rendering
operation.")

(defvar-local mistty-raw--home nil
  "Marker that tracks the position of the top of the screen, following
scrollback lines.")

(defvar-keymap mistty-raw-mode-map
  :doc "Keymap of major mode MisTTY Direct"
  "RET" #'mistty-raw-send-self
  "TAB" #'mistty-raw-send-self
  "DEL" #'mistty-raw-send-self
  "C-d" #'mistty-raw-send-self
  "C-a" #'mistty-raw-send-self
  "C-e" #'mistty-raw-send-self
  "C-p" #'mistty-raw-send-self
  "C-n" #'mistty-raw-send-self
  "C-k" #'mistty-raw-send-self
  "C-w" #'mistty-raw-send-self
  "<remap> <self-insert-command>" #'mistty-raw-send-self)

(define-derived-mode mistty-raw-mode fundamental-mode "MisTTY Direct"
  "Major mode that provides a raw terminal tied to a subprocess.

Call `mistty-raw-exec' to create the virtual terminal and start the
process."
  (use-local-map mistty-raw-mode-map))

(defun mistty-raw-exec (name program args)
  (unless (eq major-mode 'mistty-raw-mode)
    (error "Must be called from a mistty-raw-mode buffer."))
  (when (get-buffer-process (current-buffer))
    (error "A process is already attached to the buffer."))
  (mistty-log "LAUNCH %s %s" program args)
  (let ((process-environment
         (list "TERM=xterm-256color"
               (concat "INSIDE_EMACS=" emacs-version)))
        (process-connection-type t)
	(inhibit-eol-conversion t)
	(coding-system-for-read 'binary))
    (setq mistty-raw--cursor (copy-marker (point-min)))
    (setq mistty-raw--home (copy-marker (point-min)))
    (setq mistty-raw--vterm (mistty-mod-make-vterm 80 24))
    (mistty-mod-enable-scrollback mistty-raw--vterm)
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
      (process-put proc 'adjust-window-size-function #'ignore)
      (set-process-window-size proc 24 80)

      (mistty-mod-render mistty-raw--vterm (point-min) (point-max) mistty-raw--cursor)
      (goto-char mistty-raw--cursor)
      (set-process-sentinel proc #'mistty-raw--sentinel)
      (set-process-filter proc #'mistty-raw--process-filter))))

(defun mistty-raw--process-filter (proc str)
  (mistty-log "RECV %S" str)
  (mistty--with-live-buffer (process-buffer proc)
    (mistty-raw--process-bytes str)
    (mistty-raw--render)))

(defun mistty-raw--process-bytes (str)
  "Send bytes from STR to the virtual terminal to be processed.

The current buffer must have a virtual terminal associated."
  (when-let* ((vterm mistty-raw--vterm)
              (proc (get-buffer-process (current-buffer))))
    (dolist (ev (mistty-mod-process-bytes vterm (vconcat str)))
      (pcase ev
        (`(pty-write ,data)
         (mistty-log "REPLY %S" data)
         (process-send-string proc data))))))

(defun mistty-raw--render ()
  "Render the virtual terminal on the current buffer.

The current buffer must have a virtual terminal associated."
  (when-let* ((vterm mistty-raw--vterm))
    (mistty-log "RENDER")
    (save-excursion
      (goto-char mistty-raw--home)
      (unless (zerop (mistty-mod-write-scrollback vterm))
        (set-marker mistty-raw--home (point)))
      (mistty-mod-render-damaged vterm (point) (point-max) mistty-raw--cursor))
    (goto-char mistty-raw--cursor)))

(defun mistty-raw--sentinel (proc _msg)
  (when (memq (process-status proc) '(signal exit))
    (mistty--with-live-buffer (process-buffer proc)
      (setq mistty-raw--vterm nil))
    (set-process-buffer proc nil)
    (delete-process proc)))

(defun mistty-raw-launch ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*mistty-raw*")
    (mistty-raw-mode)
    (mistty-raw-exec
     (buffer-name)
     (with-connection-local-variables
      (or
       explicit-shell-file-name
       shell-file-name
       (getenv "SHELL")))
     '("-i"))
    (pop-to-buffer (current-buffer))))

(defun mistty-raw-send-self (&optional n key)
  (interactive "p")
  (if-let ((proc (get-buffer-process (current-buffer))))
      (let* ((key (or key (this-command-keys-vector)))
             (translated-key (mistty-translate-key key n)))
        (mistty-log "SEND KEY %s %s %S" n key translated-key)
        (process-send-string proc translated-key))
    (self-insert-command n key)))

(provide 'mistty-raw)

;;; mistty-raw.el ends here
