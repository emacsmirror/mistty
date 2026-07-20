;;; Tests MisTTY module integration -*- lexical-binding: t -*-

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

(require 'ert)
(require 'mistty-mod)

(ert-deftest mistty-mod-terminal ()
  (let ((term (mistty-mod-make-term 80 10)))
    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))
    (should (equal "0\n1\n2\n3\n4\n5\n6\n7\n8\n9" (mistty-mod-display-string term)))

    ;; scroll
    (mistty-mod-process-bytes term (vconcat "\r\n10"))
    (should (equal "1\n2\n3\n4\n5\n6\n7\n8\n9\n10" (mistty-mod-display-string term)))))
