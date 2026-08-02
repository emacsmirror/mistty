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
    (mistty-mod-process-bytes term (vconcat "\r0 "))
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
        (should (equal "a" (mistty-mod-display-substring term 0 0 0 0)))
        (should (equal "a\U0001F7E7" (mistty-mod-display-substring term 0 0 0 1)))
        (should (equal "a\U0001F7E7" (mistty-mod-display-substring term 0 0 0 2)))
        (should (equal "a\U0001F7E7s" (mistty-mod-display-substring term 0 0 0 3)))

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

(ert-deftest mistty-mod-scrollback-not-wrapped ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-enable-scrollback term)

    ;; The first line cannot fit into 10 columns, it'll be split by
    ;; the terminal.
    (mistty-mod-process-bytes
     term (vconcat "\rBaa, baa, black sheep have you any wool?"))
    (mistty-mod-process-bytes term (vconcat " Yes sir, yes, sir three bags full!"))
    (mistty-mod-process-bytes term (vconcat "\r\nOne for the Master"))
    (mistty-mod-process-bytes term (vconcat "\r\nand one for the Dame"))

    ;; fill the screen, moving the wrapped line into scrollback
    (dotimes (i 10)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" i))))

    (ert-with-test-buffer ()
      (goto-char (point-min))
      (should (equal 6 (mistty-mod-write-scrollback term)))
      (equal
       (concat
        "Baa, baa, black sheep have you any wool? Yes sir, yes sir, three bags full!\n"
        "One for the Master\n"
        "and one for the Dame")
       (mistty-test-content)))))

(ert-deftest mistty-mod-top-bottom-lines ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-enable-scrollback term)

    (should (equal 0 (mistty-mod-topmost-line term)))
    (should (equal 9 (mistty-mod-bottommost-line term)))
    (should (equal 19 (mistty-mod-last-column term)))

    ;; fill the screen
    (mistty-mod-process-bytes term (vconcat "\r0"))
    (dotimes (i 9)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))

    (should (equal 0 (mistty-mod-topmost-line term)))
    (should (equal 9 (mistty-mod-bottommost-line term)))

    (mistty-mod-process-bytes term (vconcat "\r\n10"))
    (mistty-mod-process-bytes term (vconcat "\r\n11"))
    (mistty-mod-process-bytes term (vconcat "\r\n12"))

    (should (equal -3 (mistty-mod-topmost-line term)))
    (should (equal 9 (mistty-mod-bottommost-line term)))

    (ert-with-test-buffer ()
      (mistty-mod-write-scrollback term)

    (should (equal 0 (mistty-mod-topmost-line term)))
    (should (equal 9 (mistty-mod-bottommost-line term)))

    (mistty-mod-process-bytes term (vconcat "\r\n13"))
    (should (equal -1 (mistty-mod-topmost-line term)))
    (should (equal 9 (mistty-mod-bottommost-line term))))))

(ert-deftest mistty-mod-cursor-point ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (should (equal '(0 . 0) (mistty-mod-cursor-point term)))
    (mistty-mod-process-bytes term (vconcat "test"))
    (should (equal '(0 . 4) (mistty-mod-cursor-point term)))
    (mistty-mod-process-bytes term (vconcat "\e[2D"))
    (should (equal '(0 . 2) (mistty-mod-cursor-point term)))
    (mistty-mod-process-bytes term (vconcat "\e[3B\e[5C"))
    (should (equal '(3 . 7) (mistty-mod-cursor-point term)))))

(ert-deftest mistty-mod-count-chars ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; full empty line
    (should (equal 20 (mistty-mod-count-chars term 0 0 0 20)))
    ;; full empty screen, 10 lines of 20 columns + newline
    (should (equal 210 (mistty-mod-count-chars term 0 0 10 0)))

    ;; line 0: regular 1-byte chars in UTF-8
    (mistty-mod-process-bytes term (vconcat "baa, baa\r\n"))

    ;; line 1: regular 1-byte chars in UTF-8
    (mistty-mod-process-bytes term (vconcat "black sheep\r\n"))

    ;; line 2: wide character: character takes 2 columns
    (mistty-mod-process-bytes term (vconcat ".\xF0\x9F\x9F\xA7....\r\n"))

    ;; line 3: combining characters: columns 2 and 4 display 2 chars
    (mistty-mod-process-bytes term (vconcat "l'e\xcc\x81te\xcc\x81.\r\n"))

    ;; line 4: zerowidth character: column 1 and 3 display 2 chars
    (mistty-mod-process-bytes term (vconcat "--\xe2\x80\x8b--\xe2\x80\x8b---\r\n"))

    ;; simple case
    (should (equal 5 (mistty-mod-count-chars term 0 0 0 5)))
    ;; empty
    (should (equal 0 (mistty-mod-count-chars term 0 0 0 0)))
    ;; full line, without newline
    (should (equal 20 (mistty-mod-count-chars term 0 0 0 20)))
    ;; full line plus newline
    (should (equal 21 (mistty-mod-count-chars term 0 0 1 0)))
    ;; partial line start
    (should (equal 16 (mistty-mod-count-chars term 0 5 1 0)))
    ;; partial line end
    (should (equal 26 (mistty-mod-count-chars term 0 0 1 5)))
    ;; multiple lines, with newlines (2 lines + 2 newlines)
    (should (equal 62 (mistty-mod-count-chars term 0 0 3 0)))

    ;; column 1 on line 2, containing a wide character, count as one
    ;; character.
    (should (equal 1 (mistty-mod-count-chars term 2 0 2 1)))
    (should (equal 2 (mistty-mod-count-chars term 2 0 2 2)))
    (should (equal 2 (mistty-mod-count-chars term 2 0 2 3)))
    (should (equal 3 (mistty-mod-count-chars term 2 0 2 4)))
    (should (equal 20 (mistty-mod-count-chars term 2 0 3 0)))

    ;; line 3 contains columns that display multiple characters
    (should (equal 1 (mistty-mod-count-chars term 3 0 3 1)))
    (should (equal 2 (mistty-mod-count-chars term 3 0 3 2)))
    (should (equal 4 (mistty-mod-count-chars term 3 0 3 3)))
    (should (equal 5 (mistty-mod-count-chars term 3 0 3 4)))
    (should (equal 7 (mistty-mod-count-chars term 3 0 3 5)))
    (should (equal 23 (mistty-mod-count-chars term 3 0 4 0)))

    ;; line 4 contains two zerowidth characters
    (should (equal 1 (mistty-mod-count-chars term 4 0 4 1)))
    (should (equal 3 (mistty-mod-count-chars term 4 0 4 2)))
    (should (equal 4 (mistty-mod-count-chars term 4 0 4 3)))
    (should (equal 6 (mistty-mod-count-chars term 4 0 4 4)))
    (should (equal 7 (mistty-mod-count-chars term 4 0 4 5)))
    (should (equal 23 (mistty-mod-count-chars term 4 0 5 0)))))

(ert-deftest mistty-mod-count-chars-invalid ()
    (let ((term (mistty-mod-make-vterm 20 10)))
      ;; end < start
      (should-error (mistty-mod-count-chars term 1 0 0 5))
      ;; invalid start line
      (should-error (mistty-mod-count-chars term -1 0 0 1))
      ;; invalid start column
      (should-error (mistty-mod-count-chars term 0 20 1 0))

      ;; invalid end line
      (should-error (mistty-mod-count-chars term 0 0 10 1))
      (should-error (mistty-mod-count-chars term 0 0 11 0))))

(ert-deftest mistty-mod-count-chars-in-scrollback ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    ;; negative line are ok when there is scrollback data
    (mistty-mod-enable-scrollback term)
    (mistty-mod-process-bytes term (vconcat "0\r\n"))
    (dotimes (i 20)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" (1+ i)))))

    (should (equal 21 (mistty-mod-count-chars term -2 0 -1 0)))))


(ert-deftest mistty-mod-count-unwrapped-lines ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes
     term (vconcat "\rBaa, baa, black sheep have you any wool?"))
    (mistty-mod-process-bytes term (vconcat " Yes sir, yes, sir three bags full!"))
    (mistty-mod-process-bytes term (vconcat "\r\nOne for the Master"))
    (mistty-mod-process-bytes term (vconcat "\r\nand one for the Dame"))

    ;; The first real line takes 4 terminal lines. The two lines after
    ;; that each take one terminal line.
    (should (equal 0 (mistty-mod-count-unwrapped-lines term 0 1)))
    (should (equal 0 (mistty-mod-count-unwrapped-lines term 0 2)))
    (should (equal 0 (mistty-mod-count-unwrapped-lines term 0 3)))
    (should (equal 1 (mistty-mod-count-unwrapped-lines term 0 4)))
    (should (equal 2 (mistty-mod-count-unwrapped-lines term 0 5)))

    ;; The real newline is at the end of line 3
    (should (equal 0 (mistty-mod-count-unwrapped-lines term 1 2)))
    (should (equal 1 (mistty-mod-count-unwrapped-lines term 3 4)))
    (should (equal 2 (mistty-mod-count-unwrapped-lines term 3 5)))

    ;; The last line is a real line
    (should (equal 3 (mistty-mod-count-unwrapped-lines term 0 6)))

    ;; Empty lines are all real
    (should (equal 3 (mistty-mod-count-unwrapped-lines term 6 9)))

    ;; The last line is real
    (should (equal 1 (mistty-mod-count-unwrapped-lines term 9 10)))))

(ert-deftest mistty-mod-count-unwrapped-lines-in-scrollback ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes
     term (vconcat "\rBaa, baa, black sheep have you any wool?"))
    (mistty-mod-process-bytes term (vconcat " Yes sir, yes, sir three bags full!"))
    (mistty-mod-process-bytes term (vconcat "\r\nOne for the Master"))
    (mistty-mod-process-bytes term (vconcat "\r\nand one for the Dame"))

    ;; fill the screen and put everything into scrollback
    (mistty-mod-enable-scrollback term)
    (dotimes (i 10)
      (mistty-mod-process-bytes term (vconcat (format "\r\n%d" i))))

    ;; count the lines in scrollback
    (should (equal 3 (mistty-mod-count-unwrapped-lines term -6 0)))))

(ert-deftest mistty-mod-count-unwrapped-lines-invalid ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (should (equal 10 (mistty-mod-count-unwrapped-lines term 0 10)))
    (should-error (mistty-mod-count-unwrapped-lines term -1 1))
    (should-error (mistty-mod-count-unwrapped-lines term 0 11))
    (should-error (mistty-mod-count-unwrapped-lines term 2 1))))

(ert-deftest mistty-mod-scrollback-wrapped-lines ()
  (let ((term (mistty-mod-make-vterm 20 10)))
    (mistty-mod-process-bytes
     term (vconcat "\rBaa, baa, black sheep have you any wool?"))
    (mistty-mod-process-bytes term (vconcat " Yes sir, yes, sir three bags full!"))
    (mistty-mod-process-bytes term (vconcat "\r\nOne for the Master"))
    (mistty-mod-process-bytes term (vconcat "\r\nand one for the Dame"))

    (mistty-mod-enable-scrollback term)
    (ert-with-test-buffer ()
      (let ((cursor (copy-marker (point-min)))
            (screen-top (copy-marker (point-min))))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (dotimes (i 4)
          (mistty-mod-process-bytes term (vconcat (format "\r\n%d" i)))
          (goto-char screen-top)
          (mistty-mod-write-scrollback term)
          (set-marker screen-top (point))
          (mistty-mod-render term screen-top (point-max) cursor))
        (should
         (equal
          (concat
           "<>Baa, baa, black shee[\n]"
           "p have you any wool?[\n]"
           " Yes sir, yes, sir t[\n]"
           "hree bags full!\n"
           "One for the Master\n"
           "and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))

        (mistty-mod-process-bytes term (vconcat "\r\n4"))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black shee[\n]"
           ;; The scrollback line above must end with a newline, even
           ;; tough it's wrapped, because the next line is a terminal
           ;; line. The newline must be marked as 'term-line-wrap.
           "<>p have you any wool?[\n]"
           " Yes sir, yes, sir t[\n]"
           "hree bags full!\n"
           "One for the Master\n"
           "and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))

        (mistty-mod-process-bytes term (vconcat "\r\n5"))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black sheep have you any wool?[\n]"
           ;; The newline within sheep, above, must have been removed
           ;; when writing the scrollback as now both terminal lines
           ;; are part of the scrollback portion of the buffer.
           "<> Yes sir, yes, sir t[\n]"
           "hree bags full!\n"
           "One for the Master\n"
           "and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))

        (mistty-mod-process-bytes term (vconcat "\r\n6"))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black sheep have you any wool? Yes sir, yes, sir t[\n]"
           "<>hree bags full!\n"
           "One for the Master\n"
           "and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5\n"
           "6")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))

        (mistty-mod-process-bytes term (vconcat "\r\n7"))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black sheep have you any wool? Yes sir, yes, sir three bags full!\n"
           "<>One for the Master\n"
           "and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5\n"
           "6\n"
           "7")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))

        (mistty-mod-process-bytes term (vconcat "\r\n8"))
        (goto-char screen-top)
        (mistty-mod-write-scrollback term)
        (set-marker screen-top (point))
        (mistty-mod-render term screen-top (point-max) cursor)
        (should
         (equal
          (concat
           "Baa, baa, black sheep have you any wool? Yes sir, yes, sir three bags full!\n"
           "One for the Master\n"
           "<>and one for the Dame\n"
           "0\n"
           "1\n"
           "2\n"
           "3\n"
           "4\n"
           "5\n"
           "6\n"
           "7\n"
           "8")
          (mistty-test-content
           :show screen-top :show-property '(term-line-wrap t))))))))

(ert-deftest mistty-mod-render-mistty-clear ()
  (let ((term (mistty-mod-make-vterm 20 10))
        (cursor (make-marker)))
    (ert-with-test-buffer ()
      (mistty-mod-render term (point-min) (point-max) cursor)
      (should (equal
               (concat "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]")
               (mistty-test-content :show-property '(mistty-clear t))))

      ;; mistty-clear identifies cells that have been explicitly
      ;; written to. It allows telling cells that contain space from
      ;; cells that are just empty.
      (mistty-mod-process-bytes term (vconcat "\e[2Chello,  \e[2Cworld. \r\n"))
      (mistty-mod-render term (point-min) (point-max) cursor)
      (should (equal
               (concat "[  ]hello,  [  ]world. [ ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]")
               (mistty-test-content :show-property '(mistty-clear t))))

      ;; mistty-clear must be reset when cells are cleared
      (mistty-mod-process-bytes term (vconcat "\e[H\e[2J"))
      (mistty-mod-render term (point-min) (point-max) cursor)
      (should (equal
               (concat "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]")
               (mistty-test-content :show-property '(mistty-clear t))))
      )))

(ert-deftest mistty-mod-render-mistty-clear-not-dim ()
  (let ((term (mistty-mod-make-vterm 20 10))
        (cursor (make-marker)))
    (ert-with-test-buffer ()
      ;; Since the DIM flag is used internally to track clear terminal
      ;; columns, DIM-related commands must be ignored. Notably \e[0m
      ;; and \e[22m must not clear DIM (but they must clear BOLD).
      (mistty-mod-process-bytes
       term (vconcat "\e[1mf\e[0moo\r\n\e[1mb\e[22mar\r\n\e[2mnot dim\e[0m\r\n"))
      (mistty-mod-render term (point-min) (point-max) cursor)

      (should (equal
               (concat "foo[                 ]\n"
                       "bar[                 ]\n"
                       "not dim[             ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]\n"
                       "[                    ]")
               (mistty-test-content :show-property '(mistty-clear t))))
      (should (equal
               (concat "[f]oo\n"
                       "[b]ar\n"
                       "not dim")
               (mistty-test-content :show-property '(face ansi-color-bold)))))))
