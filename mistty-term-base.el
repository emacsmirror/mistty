;;; mistty-term-base.el --- Generic methods for terminal access -*- lexical-binding: t -*-

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
;; This file defines generic methods called by mistty to communicate
;; with the selected terminal type (builtin or mod).

(require 'cl-lib)

(cl-defgeneric mistty--create-term (type name program args width height)
  "Create a new term buffer of the given TYPE with name NAME.

The buffer runs PROGRAM with the given ARGS.

LOCAL-MAP specifies a local map to be used as the char-mode map.

WIDTH and HEIGHT are the initial dimension of the terminal
reported to the remote process.

This function returns an instance of the generic terminal type, which
allows getting hold of the buffer and process.")

(cl-defgeneric mistty--term-buf (term)
  "Return the terminal buffer.")

(cl-defgeneric mistty--term-proc (term)
  "Return the terminal process.")

(cl-defgeneric mistty--term-home-marker (term)
  "Return the marker for the start of the terminal.

The marker is only valid in the terminal buffer.")

(cl-defgeneric mistty--term-lines (term)
  "Return the height of the terminal, in lines.")

(cl-defgeneric mistty--term-columns (term)
  "Return the width of the terminal, in columns.")

(cl-defgeneric mistty--term-sentinel-func (term)
  "Return the hardcoded sentinel function or the terminal.")

(cl-defgeneric mistty--term-filter-func (term)
  "Return the hardcoded filter function or the terminal.")

(defun mistty--term-sentinel (proc msg)
  "Call the hardcoded sentinel function.

This might be different from the sentinel set on PROC."
  (funcall (mistty--term-sentinel-func (process-get proc 'mistty-term)) proc msg))

(cl-defgeneric mistty--term-resize (term width height)
  "Set the terminal size for TERM to WIDTH x HEIGHT.")

(cl-defgeneric mistty--term-autoresize (term enable)
  "Enable or disable auto-resizing based on the buffer windows.")

(defun mistty--term-is-term-buffer (buffer)
  "Return non-nil if BUFFER is a term buffer."
  (when-let* ((proc (get-buffer-process buffer)))
    (process-get proc 'mistty-term)))

(cl-defgeneric mistty--term-setup-buffer (term fullscreen)
  "Prepare the buffer for use.

If FULLSCREEN is non-nil, prepare the buffer for fullscreen mode")

(cl-defgeneric mistty--term-setup-accum-for-fullscreen
    (term accum leave-fullscreen-func)
  "Register processors for TERM on ACCUM in fullscreen mode.

LEAVE-FULLSCREEN-FUNC is a function that takes the TERM instance and
leaves fullscreen mode.")

(cl-defgeneric mistty--term-setup-accum
    (term accum enter-fullscreen-func)
  "Register processors for TERM on ACCUM in normal mode.

ENTER-FULLSCREEN-FUNC is a function that takes he TERM instance and
enters fullscreen mode.")

(provide 'mistty-term-base)

;;; mistty-term-base.el ends here

