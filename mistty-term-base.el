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

This function returns an instance of the generic terminal type.")

(cl-defgeneric mistty--term-buf (term)
  "Return the terminal buffer.")

(cl-defgeneric mistty--term-proc (term)
  "Return the terminal process.")

(provide 'mistty-term-base)

;;; mistty-term-base.el ends here

