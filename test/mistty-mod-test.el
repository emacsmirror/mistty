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
(require 'mistty-testing)
(require 'turtles)

(ert-deftest mistty-mod-process-bytes ()
  (let ((term (mistty-mod-make-vterm 80 10)))
    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))
    (should (equal "0\n1\n2\n3\n4\n5\n6\n7\n8\n9" (mistty-mod-display-string term)))

    ;; scroll
    (mistty-mod-process-bytes term (vconcat "\r\n10"))
    (should (equal "1\n2\n3\n4\n5\n6\n7\n8\n9\n10" (mistty-mod-display-string term)))))

(ert-deftest mistty-mod-render ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))
    (ert-with-test-buffer ()
      (insert "terminal:\n")
      (let ((term-start (copy-marker (point)))
            (term-end nil))
        (insert "---")
        (setq term-end (copy-marker (point)))
        (insert "\nend.")

        (mistty-mod-render term term-start term-end)
        (should
         (equal
          (concat
           "terminal:\n"
           "0                   \n"
           "1                   \n"
           "2                   \n"
           "3                   \n"
           "4                   \n"
           "5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n"
           "\n"
           "end.")
          (buffer-string)))))))

(ert-deftest mistty-mod-set-cursor ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))
    (goto-char (point-min))
    (ert-with-test-buffer ()
        (mistty-mod-render term (point-min) (point-max))
        (should
         (equal
          (concat
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5\n"
           "6\n"
           "7\n"
           "8\n"
           "9<>")
          (mistty-test-content :show (point))))

        ;; move cursor 3 lines up, 2 columns right
        (mistty-mod-process-bytes term (vconcat "\e[3A\e[2C"))
        (mistty-mod-render term (point-min) (point-max))
        (should
         (equal
          (concat
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5\n"
           "6  <>\n"
           "7\n"
           "8\n"
           "9")
          (mistty-test-content :show (point)))))))

(turtles-ert-deftest mistty-mod-set-color (:instance 'mistty)
 (ert-with-test-buffer ()
   (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[31mred\e[0m, \e[37m\e[42mgreen\e[0m, \e[34mblue\e[0m."))
    (mistty-mod-render term (point-min) (point-max))
    (turtles-with-grab-buffer ()
      (goto-char (point-min))
      (should
       (equal
        "red, green, blue."
        (buffer-substring-no-properties (pos-bol) (pos-eol))))

      (mistty-test-goto "red")
      (should
       (equal (mistty-colors-at-point)
              (mistty-face-colors 'ansi-color-red 'default)
              ))

      (mistty-test-goto ",")
      (should
       (equal (mistty-colors-at-point)
              (mistty-face-colors 'default)))

      (mistty-test-goto "green")
      (should
       (equal (mistty-colors-at-point)
              (mistty-face-colors 'ansi-color-white 'ansi-color-green)))

      (mistty-test-goto "blue")
      (should
       (equal (mistty-colors-at-point)
              (mistty-face-colors 'ansi-color-blue 'default)))))))


(ert-deftest mistty-mod-set-face ()
 (ert-with-test-buffer ()
   (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[1mbold, \e[3mitalic\e[0m,\r\n\e[4munderline\e[0m,\r\n\e[7minverse\e[0m."))
    (mistty-mod-render term (point-min) (point-max))

    (goto-char (point-min))
    (should
     (equal
      "bold, italic,\nunderline,\ninverse."
      (mistty-test-content)))

    (mistty-test-goto "bold")
    (should (equal 'ansi-color-bold (get-text-property (point) 'face)))

    (mistty-test-goto "italic")
    (should (equal '(ansi-color-bold ansi-color-italic) (get-text-property (point) 'face)))

    (mistty-test-goto "underline")
    (should (equal 'ansi-color-underline (get-text-property (point) 'face)))

    (mistty-test-goto "inverse")
    (should (equal 'ansi-color-inverse (get-text-property (point) 'face))))))

;; TODO:
;;  - test all indexed colors: standard, bright, 6x6x6 cube, grayscale
;;    compare with
;;    https://lucianofedericopereira.github.io/xterm-colors-cheat-sheet/
;;    https://color-palette.hexdocs.pm/ansi_color_codes.html
;;  - test 24bit colors
