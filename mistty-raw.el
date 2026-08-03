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
(eval-when-compile
  (require 'cl-lib))

(defvar explicit-shell-file-name) ;; defined in shell

(defvar-local mistty-raw--vterm nil
  "Virtual terminal tied to the buffer, from mistty-mod.")

(defvar-local mistty-raw--cursor nil
  "Marker that tracks the cursor position, set by the last rendering
operation.")

(defvar-local mistty-raw--home nil
  "Marker that tracks the position of the top of the screen, following
scrollback lines.")

(defvar-local mistty-raw--home-scrolline nil
  "Scrolline that correspond to `mistty-raw--home'")

(defvar-local mistty-raw-width nil
  "Width of the terminal, in columns. Set by `mistty-raw-resize'.")

(defvar-local mistty-raw-height nil
  "Height of the terminal, in lines. Set by `mistty-raw-resize'.")

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

(defun mistty-raw-exec (name program args width height)
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
    (setq mistty-raw--home-scrolline 0)
    (setq mistty-raw-width width)
    (setq mistty-raw-height height)
    (setq mistty-raw--vterm (mistty-mod-make-vterm width height))
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
		               height width "/dev/null")
	               ".."
	               program args)))
      ;; Window size must be adjusted manually with mistty-raw--resize
      (process-put proc 'adjust-window-size-function #'ignore)

      ;; start-file-process doesn't always respect
      ;; coding-system-for-read. Force it.
      (set-process-coding-system proc 'binary (cdr (process-coding-system proc)))

      (mistty-mod-render mistty-raw--vterm (point-min) (point-max) mistty-raw--cursor)
      (goto-char mistty-raw--cursor)
      (set-process-sentinel proc #'mistty-raw--sentinel)
      (set-process-filter proc #'mistty-raw--process-filter))))

(defun mistty-raw-resize (width height)
  "Resize the terminal and pty to WIDTH x HEIGHT."
  (if (or (/= mistty-raw-width width) (/= mistty-raw-height height))
      (when-let* ((vterm mistty-raw--vterm)
                  (proc (get-buffer-process (current-buffer))))
        (mistty-mod-resize vterm width height)
        (set-process-window-size proc height width))))

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
    (save-excursion
      (goto-char mistty-raw--home)
      (cl-incf mistty-raw--home-scrolline (mistty-mod-clear-scrollback vterm))
      (mistty-log "RENDER @%s" mistty-raw--home-scrolline)
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
     ;; select window right away to get its dimensions
    (pop-to-buffer (current-buffer))
    (mistty-raw-exec
     (buffer-name)
     (with-connection-local-variables
      (or
       explicit-shell-file-name
       shell-file-name
       (getenv "SHELL")))
     '("-i")
     (window-max-chars-per-line)
     (floor (window-screen-lines)))))

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
