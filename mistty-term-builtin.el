;;; mistty-term-builtin.el --- Use term.el to create the terminal -*- lexical-binding: t -*-

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
;; on top of Emacs builtin terminal, term.el.

(require 'mistty-term-base)
(require 'mistty-raw)

(cl-defstruct (mistty--term-builtin
               (:constructor mistty--make-term-builtin)
               (:copier nil))
  proc buf)


(cl-defmethod mistty--create-term ((_type (eql 'builtin)) _name _program _args _width _height)
  (mistty--make-term-builtin))


(provide 'mistty-term-builtin)

;;; mistty-term-builtin.el ends here
