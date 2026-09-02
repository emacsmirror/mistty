;;; mistty-alacritty.el --- Raw alacritty-based terminal -*- lexical-binding: t -*-

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
;; This file defines a mode that provides direct access to an
;; alacritty-based terminal, with none of the extra features and
;; overhead of MisTTY. The result is similar to term.el in raw mode.

(require 'mistty-alacritty-vt)
(require 'mistty-util)
(require 'mistty-kbd)
(require 'mistty-log)
(require 'mistty-scrolline)
(eval-when-compile
  (require 'cl-lib))
(require 'ansi-osc) ; links use ansi-osc-hyperlink

(defvar explicit-shell-file-name) ;; defined in shell

(defcustom mistty-term-name nil
  "Value for the TERM env variable for the virtual terminal.

This should be set to alacritty or alacritty-direct, as long as the
alacritty terminal definition is installed. This is necessary for
truecolor (24bit) support.

See https://github.com/alacritty/alacritty/blob/master/INSTALL.md#terminfo

For backward compatibility, you may want set it to xterm-256color or
even xterm.

If this is nil, MisTTY checks whether the alacritty terminfo is present
on the system and automatically falls back to xterm-256color."
  :group 'mistty
  :type 'string)

(defvar-local mistty-alacritty--vterm nil
  "Virtual terminal tied to the buffer, from mistty-alacritty-vt.")

(defvar-local mistty-alacritty--cursor nil
  "Marker that tracks the cursor position, set by the last rendering
operation.")

(defvar-local mistty-alacritty--home nil
  "Marker that tracks the position of the top of the screen, following
scrollback lines.")

(defvar-local mistty-alacritty-columns nil
  "Width of the terminal, in columns. Set by `mistty-alacritty-resize'.")

(defvar-local mistty-alacritty-lines nil
  "Height of the terminal, in lines. Set by `mistty-alacritty-resize'.")

(defvar mistty-alacritty-mode-map
  (let ((map (make-sparse-keymap))
        (esc-map (make-sparse-keymap)))
    ;; This builds a map very similar to term raw-keymap.
    (dotimes (c 128)
      (unless (memq c '(?\C-c ?\C-x))
        (define-key map (make-string 1 c) 'mistty-send-key)))
    (define-key map "\e" esc-map)
    (dotimes (c 128)
      (unless (memq c '(?O ?\[))
        (define-key esc-map (make-string 1 c) 'mistty-send-key)))

    ;; C-q <any key> sends that key to the terminal unmodified
    (define-key map "\C-q" '(keymap (t . mistty-send-last-key)))

    (dolist (key '([mouse-2] [up] [down] [right] [left] [C-up] [C-down]
                   [C-right] [C-left] [delete] [deletechar] [backspace]
                   [home] [end] [insert] [S-prior] [S-next] [S-insert]
                   [prior] [next] [?\C-/] [?\C- ] [?\C-\M-/] [?\C-\M- ]))
      (define-key map key 'mistty-send-key))

    ;; Mirror keybindings from mistty-mode-map, for consistency.
    (keymap-set map "C-c C-c" #'mistty-send-last-key)
    (keymap-set map "C-c C-z" #'mistty-send-last-key)
    (keymap-set map "C-c C-\\" #'mistty-send-last-key)
    (keymap-set map "C-c C-g" #'mistty-send-last-key)
    (keymap-set map "C-c C-q" #'mistty-send-key-sequence)
    ;; TODO: support xterm-paste?

  map)
  "Keymap of major mode MisTTY Alacritty.

This intercepts all major key bindings and sends them to the terminal.
Overwrite to recover key bindings.")

(define-derived-mode mistty-alacritty-mode fundamental-mode "MisTTY Direct"
  "Major mode that provides a raw terminal tied to a subprocess.

Call `mistty-alacritty-exec' to create the virtual terminal and start the
process."
  ;; Face is set manually; disable font-lock mode
  (font-lock-mode -1)
  (jit-lock-mode nil)

  (use-local-map mistty-alacritty-mode-map))

(defun mistty-alacritty-exec (name program args width height)
  (unless (eq major-mode 'mistty-alacritty-mode)
    (error "Must be called from a mistty-alacritty-mode buffer."))
  (when (get-buffer-process (current-buffer))
    (error "A process is already attached to the buffer."))
  (mistty-log "LAUNCH %s %s" program args)
  (let ((width (or width 80))
        (height (or height 24))
        (process-environment
         (nconc
          (list (concat "TERM=" (mistty-alacritty--TERM))
                (concat "INSIDE_EMACS=" emacs-version))
          process-environment))
        (process-connection-type t)
	(inhibit-eol-conversion t)
	(coding-system-for-read 'binary))
    (jit-lock-mode nil) ;; in case this was turned on by a hook
    (setq mistty-alacritty--cursor (copy-marker (point-min)))
    (setq mistty-alacritty--home (copy-marker (point-min)))
    (set-marker-insertion-type mistty-alacritty--home nil)
    (mistty--init-scrolline mistty-alacritty--home 0)
    (setq mistty-alacritty-columns width)
    (setq mistty-alacritty-lines height)
    (mistty-log "MAKE VTERM %s lines, %s colums" height width)
    (setq mistty-alacritty--vterm (mistty-alacritty-vt-make-vterm width height))
    (mistty-alacritty-vt-enable-scrollback mistty-alacritty--vterm)
    (let ((proc (apply #'start-file-process name (current-buffer)
                       ;; On Android, /bin doesn't exist, and the default shell is
                       ;; found as /system/bin/sh.
	               (if (eq system-type 'android)
                           "/system/bin/sh"
                         "/bin/sh")
                       "-c"
	               (format "stty -nl echo rows %d columns %d sane erase %s 2>%s;\
if [ $1 = .. ]; then shift; fi; exec \"$@\""
		               height width
                               (pcase mistty-del
                                       ("\C-h" "^H")
                                       ("\d" "^?"))
                               ;; TODO: choose appropriate null-device
                               "/dev/null")
	               ".."
	               program args)))
      ;; Window size must be adjusted manually with mistty-alacritty--resize
      (process-put proc 'adjust-window-size-function #'ignore)

      ;; start-file-process doesn't always respect
      ;; coding-system-for-read. Force it.
      (set-process-coding-system proc 'binary (cdr (process-coding-system proc)))

      (goto-char (point-min))
      (mistty-alacritty-vt-render mistty-alacritty--vterm mistty-alacritty--cursor)
      (goto-char mistty-alacritty--cursor)
      (set-marker (process-mark proc) mistty-alacritty--cursor)
      (set-process-sentinel proc #'mistty-alacritty--sentinel)
      (set-process-filter proc #'mistty-alacritty--process-filter))))

(defun mistty-alacritty-auto-resize (enabled)
  "Track window size and automatically resize the terminal.

Enabling auto-resize might trigger an immediate resize if the terminal
doesn't match the desired window size.

Set ENABLED to non-nil to enable automatic resize to nil to disable it."
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (if enabled
        (progn
          (process-put proc 'adjust-window-size-function #'mistty-alacritty--resize-from-window)
          (when-let ((wins (get-buffer-window-list)))
            (mistty-alacritty--resize-from-window proc wins)))
      (process-put proc 'adjust-window-size-function #'ignore))))

(defun mistty-alacritty--resize-from-window (proc win)
  "Choose window size and apply it to the virtual terminal.

This is meant to be used as adjust-process-window-size function on the
process. PROC is the process, WIN the set of windows displaying the
process buffer. The current buffer is the process buffer.

This function updates the virtual terminal size and returns the new
size.

Calls `window-adjust-process-window-size' to choose the appropriate size
given the set of windows."
  (when-let* ((size (funcall window-adjust-process-window-size-function proc win)))
    (mistty-alacritty-resize (car size) (cdr size))
    size))

(defun mistty-alacritty-resize (width height)
  "Resize the terminal and pty to WIDTH x HEIGHT."
  (if (or (/= mistty-alacritty-columns width) (/= mistty-alacritty-lines height))
      (when-let* ((vterm mistty-alacritty--vterm)
                  (proc (get-buffer-process (current-buffer))))
        (mistty-log "RESIZE: %s lines %s columns" height width)
        (mistty-alacritty-vt-resize vterm width height)
        (setq mistty-alacritty-columns width)
        (setq mistty-alacritty-lines height)
        (set-process-window-size proc height width))))

(defun mistty-alacritty--alt-screen-p ()
  (mistty-alacritty-vt-alt-screen-p mistty-alacritty--vterm))

(defun mistty-alacritty--cursor-linecol ()
  (mistty-alacritty-vt-cursor mistty-alacritty--vterm))

(defun mistty-alacritty--cursor-column ()
  (cdr (mistty-alacritty-vt-cursor mistty-alacritty--vterm)))

(defun mistty-alacritty--cursor-chars ()
  "Return char index of the cursor within its line.

Do not confuse it with `mistty-alacritty--cursor-column'"
  (- mistty-alacritty--cursor (save-excursion
                          (goto-char mistty-alacritty--cursor)
                          (pos-bol))))

(defun mistty-alacritty--cursor-line ()
  (car (mistty-alacritty-vt-cursor mistty-alacritty--vterm)))

(defun mistty-alacritty--process-filter (proc str)
  (mistty-log "RECV %S" str)
  (mistty--with-live-buffer (process-buffer proc)
    (mistty-alacritty--process-bytes str)
    (mistty-alacritty--render)))

(defun mistty-alacritty--process-bytes (str)
  "Send bytes from STR to the virtual terminal to be processed.

The current buffer must have a virtual terminal associated."
  (when-let* ((vterm mistty-alacritty--vterm)
              (proc (get-buffer-process (current-buffer))))
    (dolist (ev (mistty-alacritty-vt-process-bytes vterm (vconcat str)))
      (pcase ev
        (`(pty-write ,data)
         (mistty-log "REPLY %S" data)
         (process-send-string proc data))))))

(defun mistty-alacritty--render ()
  "Render the virtual terminal on the current buffer.

The current buffer must have a virtual terminal associated."
  (when-let* ((vterm mistty-alacritty--vterm))
    (save-excursion
      (goto-char mistty-alacritty--home)
      (cl-incf mistty--scrolline-home-num (mistty-alacritty-vt-write-scrollback vterm))
      (set-marker mistty-alacritty--home (point))
      (mistty-alacritty-vt-render-damaged vterm mistty-alacritty--cursor)
      (mistty-log "RENDER @%s" mistty--scrolline-home-num)
      (when-let ((proc (get-buffer-process (current-buffer))))
        (when (process-live-p proc)
          (set-marker (process-mark proc) mistty-alacritty--cursor))))
    (goto-char mistty-alacritty--cursor)))

(defun mistty-alacritty--sentinel (proc msg)
  (when (memq (process-status proc) '(signal exit))
    (mistty--with-live-buffer (process-buffer proc)
      (save-excursion
        (goto-char (point-max))
        (insert "\nProcess %s" msg)))
    (set-process-buffer proc nil)
    (delete-process proc)))

(defun mistty-alacritty-launch ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*mistty-alacritty*")
    (mistty-alacritty-mode)
     ;; select window right away to get its dimensions
    (pop-to-buffer (current-buffer))
    (mistty-alacritty-exec
     (buffer-name)
     (with-connection-local-variables
      (or
       explicit-shell-file-name
       shell-file-name
       (getenv "SHELL")))
     '("-i")
     (window-max-chars-per-line)
     (floor (window-screen-lines)))))

(defun mistty-alacritty--TERM ()
  "Choose a value for the TERM env variable.

This is controlled by the custom variable `mistty-term-name'"
  (cond
   (mistty-term-name mistty-term-name)
   ((shell-command-to-string "infocmp alacritty") "alacritty")
   (t "xterm-256color")))

(defun mistty-alacritty--clear-to-eol (pos)
  "Mark spaces from POS to the end of the line as clear."
  (when-let* ((vterm mistty-alacritty--vterm))
    (when (> pos mistty-alacritty--home)
      (mistty-alacritty-vt-clear-to-eol vterm
                               (mistty--count-lines mistty-alacritty--home pos)
                               (- pos (mistty--bol pos))))))

(defun mistty-alacritty--cleanup-prompt-sp (pos)
  "Cleanup after the shell using the prompt-sp hack.

POS should be the position where the CR is called in the prompt-sp
sequence."
  (when-let* ((vterm mistty-alacritty--vterm))
    (when (> pos mistty-alacritty--home)
      (mistty-alacritty-vt-cleanup-prompt-sp
       vterm
       (mistty--count-lines mistty-alacritty--home pos)))))


(provide 'mistty-alacritty)

;;; mistty-alacritty.el ends here
