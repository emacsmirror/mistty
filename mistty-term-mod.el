;;; mistty-term-mod.el --- Use term.el to create the terminal -*- lexical-binding: t -*-

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
;; This file implements generic methods defined in mistty-term-base.el
;; on top of mistty-raw.el

(require 'cl-lib)
(require 'mistty-term-base)
(require 'mistty-raw)
(require 'mistty-term)

(cl-defstruct (mistty--term-mod
               (:constructor mistty--make-term-mod)
               (:copier nil))
  proc buf)

(cl-defmethod mistty--create-term ((_type (eql 'mod)) name program args width height)
  (let ((term-buffer (generate-new-buffer name 'inhibit-buffer-hooks)))
    (with-current-buffer term-buffer
      (mistty-raw-mode)
      (setq-local mistty--prompt-cell (mistty--make-prompt-cell))
      (setq-local scroll-margin 0)
      (let ((process-environment
             (if (with-connection-local-variables mistty-set-EMACS)
                 (cons (format "EMACS=%s" emacs-version)
                       process-environment)
               process-environment)))
        (mistty-raw-exec name program args width height))
      (let* ((proc (get-buffer-process term-buffer))
             (term (mistty--make-term-mod :buf term-buffer :proc proc)))
        (set-process-filter proc (mistty--make-accumulator
                                  (mistty--term-filter-func term)))
        (process-put proc 'mistty-term term)

        term))))

(cl-defmethod mistty--term-buf ((term mistty--term-mod))
  (mistty--term-mod-buf term))

(cl-defmethod mistty--term-proc ((term mistty--term-mod))
  (mistty--term-mod-proc term))

(cl-defmethod mistty--term-home-marker ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw--home))

(cl-defmethod mistty--term-home-scrolline ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    (or mistty-raw--home-scrolline 0)))

(cl-defmethod mistty--term-lines ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw-lines))

(cl-defmethod mistty--term-columns ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw-columns))

(cl-defmethod mistty--term-sentinel-func ((_term mistty--term-mod))
  #'mistty-raw--sentinel)

(cl-defmethod mistty--term-filter-func ((_term mistty--term-mod))
  #'mistty-raw--process-filter)

(cl-defmethod mistty--term-resize ((term mistty--term-mod) width height)
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw-resize width height))
  (set-process-window-size (mistty--term-mod-proc term) height width))

(cl-defmethod mistty--term-autoresize ((term mistty--term-mod) enable)
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw-auto-resize enable)))

(provide 'mistty-term-mod)

;;; mistty-term-mod.el ends here
