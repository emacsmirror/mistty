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
      (let ((cursor (make-marker))
            (term-start (copy-marker (point)))
            (term-end nil))
        (insert "---")
        (setq term-end (copy-marker (point)))
        (insert "\nend.")

        (mistty-mod-render term term-start term-end cursor)
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
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
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
          (mistty-test-content :show cursor)))

        ;; move cursor 3 lines up, 2 columns right
        (mistty-mod-process-bytes term (vconcat "\e[3A\e[2C"))
        (mistty-mod-render term (point-min) (point-max) cursor)
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
          (mistty-test-content :show cursor)))))))

(turtles-ert-deftest mistty-mod-set-color (:instance 'mistty)
 (ert-with-test-buffer ()
   (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[31mred\e[0m, \e[37m\e[42mgreen\e[0m, \e[34mblue\e[0m."))
    (mistty-mod-render term (point-min) (point-max) (make-marker))
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

(turtles-ert-deftest mistty-mod-set-24bit-color (:instance 'mistty)
 (ert-with-test-buffer ()
   (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes
     term (vconcat "\e[38;2;237;237;216m\e[48;2;97;35;196mcolorful\e[0m!"))
    (mistty-mod-render term (point-min) (point-max) (make-marker))
    (turtles-with-grab-buffer ()
      (goto-char (point-min))
      (should
       (equal
        "colorful!"
        (buffer-substring-no-properties (pos-bol) (pos-eol))))

      (mistty-test-goto "colorful")
      (should
       (equal (mistty-colors-at-point)
              '("#ededd8" "#6123c4")))))))


(ert-deftest mistty-mod-set-face ()
 (ert-with-test-buffer ()
   (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[1mbold, \e[3mitalic\e[0m,\r\n\e[4munderline\e[0m,\r\n\e[7minverse\e[0m."))
    (mistty-mod-render term (point-min) (point-max) (make-marker))

    (goto-char (point-min))
    (should
     (equal
      "bold, italic,\nunderline,\ninverse."
      (mistty-test-content)))

    (mistty-test-goto "bold")
    (should (equal 'ansi-color-bold (get-text-property (point) 'face)))

    (mistty-test-goto "italic")
    (should (equal (sort '(ansi-color-bold ansi-color-italic))
                   (sort (get-text-property (point) 'face))))

    (mistty-test-goto "underline")
    (should (equal 'ansi-color-underline (get-text-property (point) 'face)))

    (mistty-test-goto "inverse")
    (should (equal 'ansi-color-inverse (get-text-property (point) 'face))))))

(ert-deftest mistty-mod-render-damaged-move-cursor ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))
    (goto-char (point-min))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
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
          (mistty-test-content :show cursor)))

        ;; move cursor 3 lines up, 2 columns right
        (mistty-mod-process-bytes term (vconcat "\r\e[3A\e[2Cmodified\r\e[2A\e[2C"))
        (mistty-mod-render-damaged term (point-min) (point-max) cursor)
        (should
         (equal
          (concat
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4 <>\n"        ; not modified, but the cursor moved there
           "5\n"
           "6 modified\n"  ; modified
           "7\n"
           "8\n"
           "9")            ; not modified, but the cursor moved from there
          (mistty-test-content :show cursor)))))))

(ert-deftest mistty-mod-pty-write ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; \e[6n queries the cursor position. ]
    (should (equal nil (mistty-mod-process-bytes term (vconcat "foo\r\n"))))
    (should (equal
             '((pty-write "\33[2;4R"))
             (mistty-mod-process-bytes term (vconcat "bar\e[6n\r\n"))))))

(ert-deftest mistty-mod-render-unicode-wide-characters ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[1ma\e[0m\xF0\x9F\x9F\xA7\e[4msquare\e[0m!\r\n"))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        ;; Alacritty puts fake columns around wide chars to keep the column aligned. Make
        ;; sure these don't appear in the Emacs text.
        (should
         (equal
           "a\U0001F7E7square!"
          (mistty-test-content)))

        ;; The following makes sure that the text properties are
        ;; applied to the right portion of the text, despite the
        ;; calculations being possibly thrown off by the fake columns.
        (should
         (equal
           "[a]\U0001F7E7square!"
          (mistty-test-content :show-property '(face ansi-color-bold))))
        (should
         (equal
           "a\U0001F7E7[square]!"
          (mistty-test-content :show-property '(face ansi-color-underline))))))))


(ert-deftest mistty-mod-render-unicode-combining-characters ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes term (vconcat "\e[1mc'e\xcc\x81tait\e[0m \e[4ml'e\xcc\x81te\xcc\x81\e[0m!\r\n"))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        ;; The following makes sure that the text properties are
        ;; applied to the right portion of the text, despite the
        ;; calculations being possibly thrown off by and é (e\u0301)
        ;; counting as two characters in the emacs buffer, even though
        ;; it's displayed in a single column.
        (should
         (equal
           "[c'e\u0301tait] l'e\u0301te\u0301!"
          (mistty-test-content :show-property '(face ansi-color-bold))))
        (should
         (equal
           "c'e\u0301tait [l'e\u0301te\u0301]!"
          (mistty-test-content :show-property '(face ansi-color-underline))))))))

(ert-deftest mistty-mod-render-unicode-zerowidth-characters ()
  (let ((term (mistty-mod-make-vterm 80 10)))
    (mistty-mod-process-bytes
     term (vconcat "https://example.com/\xe2\x80\x8b\e[1mvery\e[0m/\xe2\x80\x8blong/\xe2\x80\x8b\e[1mpath\e[0m.\r\n"))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        ;; The zerowidth chars must be there. They must not have
        ;; thrown off the text property computations.
        (should
         (equal
           "https://example.com/\u200b[very]/\u200blong/\u200b[path]."
          (mistty-test-content :show-property '(face ansi-color-bold))))
        ))))

(ert-deftest mistty-mod-render-unicode-joiner ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes
     term (vconcat
           ;; 👨 (Man) + [ZWJ] + 👩 (Woman) + [ZWJ] + 👧 (Girl)
           "\e[1m\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\e[0m.\r\n"))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        ;; The joiner must not have thrown off the text property
        ;; computations (no matter how alacritty decided to render
        ;; it.)
        (should
         (equal
          "[👨\u200d👩\u200d👧]."
          (mistty-test-content :show-property '(face ansi-color-bold))))
        ))))

(ert-deftest mistty-mod-scrollback-enabled ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-enable-scrollback term)

    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))

    (ert-with-test-buffer ()
      (let ((cursor (make-marker))
            (screen-top (make-marker)))
        (should (equal 0 (mistty-mod-write-scrollback term)))
        (should (equal "" (buffer-string)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        (should
         (equal
          (concat
           "0                   \n"
           "1                   \n"
           "2                   \n"
           "3                   \n"
           "4                   \n"
           "5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n")
          (mistty-test-content :trim nil)))

        (mistty-mod-process-bytes term (vconcat "\r\n10"))
        (mistty-mod-process-bytes term (vconcat "\r\n11"))

        ;; the scrollback lines are written before the start
        ;; of the buffer
        (goto-char (point-min))
        (should (equal 2 (mistty-mod-write-scrollback term)))
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "0                   \n"
           "1                   \n"
           "<>2                   \n"
           "3                   \n"
           "4                   \n"
           "5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n"
           "10                  \n"
           "11                  \n")
          (mistty-test-content :show screen-top
                               :trim nil)))

        (mistty-mod-process-bytes term (vconcat "\r\n12"))
        (mistty-mod-process-bytes term (vconcat "\r\n13"))
        (mistty-mod-process-bytes term (vconcat "\r\n14"))

        ;; next time, only the additional scrollback lines
        ;; are written, so 3 lines, not 5.
        (goto-char screen-top)
        (should (equal 3 (mistty-mod-write-scrollback term)))
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "0                   \n"
           "1                   \n"
           "2                   \n"
           "3                   \n"
           "4                   \n"
           "<>5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n"
           "10                  \n"
           "11                  \n"
           "12                  \n"
           "13                  \n"
           "14                  \n")
          (mistty-test-content :show screen-top
                               :trim nil)))

        ))))


(ert-deftest mistty-mod-scrollback-disabled ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; unnecessary, as scrollback is disabled by default
    ;; (mistty-mod-disable-scrollback term)

    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))

    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        (should
         (equal
          (concat
           "0                   \n"
           "1                   \n"
           "2                   \n"
           "3                   \n"
           "4                   \n"
           "5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n")
          (mistty-test-content :trim nil)))

        (mistty-mod-process-bytes term (vconcat "\r\n10"))
        (mistty-mod-process-bytes term (vconcat "\r\n11"))

        ;; There's no scrollback to write
        (goto-char (point-min))
        (should (equal 0 (mistty-mod-write-scrollback term)))
        (mistty-mod-render term (point) (point-max) cursor)
        (should
         (equal
          (concat
           "2                   \n"
           "3                   \n"
           "4                   \n"
           "5                   \n"
           "6                   \n"
           "7                   \n"
           "8                   \n"
           "9                   \n"
           "10                  \n"
           "11                  \n")
          (mistty-test-content :trim nil)))

        ))))

(ert-deftest mistty-mod-mark-line-wrap ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; fill the screen
    (mistty-mod-process-bytes
     term (vconcat "\rBaa, baa, black sheep have you any wool?"))
    (mistty-mod-process-bytes term (vconcat " Yes sir, yes, sir three bags full!"))
    (mistty-mod-process-bytes term (vconcat "\r\nOne for the Master"))
    (mistty-mod-process-bytes term (vconcat "\r\nand one for the Dame"))
    (goto-char (point-min))
    (ert-with-test-buffer ()
      (let ((cursor (make-marker)))
        (mistty-mod-render term (point-min) (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black shee[\n]"
           "p have you any wool?[\n]"
           " Yes sir, yes, sir t[\n]"
           "hree bags full!\n"
           "One for the Master\n"
           "and one for the Dame")
          (mistty-test-content :show-property '(term-line-wrap t))))))))
