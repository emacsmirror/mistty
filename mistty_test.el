;;; Tests mistty.el -*- lexical-binding: t -*-

(require 'mistty)
(require 'term)
(require 'ert)
(require 'ert-x)

(eval-when-compile
   ;; defined in term
  (defvar term-width))

(defvar mistty-test-bash-exe (executable-find "bash"))
(defvar mistty-test-zsh-exe (executable-find "zsh"))

(defconst mistty-test-prompt "$ ")

(defmacro with-mistty-buffer (&rest body)
  `(ert-with-test-buffer ()
     (mistty-test-setup 'bash)
     ,@body))

(defmacro with-mistty-buffer-zsh (&rest body)
  `(ert-with-test-buffer ()
     (mistty-test-setup 'zsh)
     ,@body))

(defmacro with-mistty-buffer-selected (&rest body)
  `(save-window-excursion
     (with-mistty-buffer
      (with-selected-window (display-buffer (current-buffer))
        ,@body))))

(defmacro mistty-run-command (&rest body)
  `(progn
     (mistty-pre-command)
     (progn ,@body)
     (let ((timer (mistty-post-command)))
       (while (memq timer timer-list)
         (timer-event-handler timer)))))

(ert-deftest test-mistty-simple-command ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo hello\n")
   (should (equal "hello" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-simple-command-zsh ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo hello\n")
   (should (equal "hello" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-keystrokes ()
  (with-mistty-buffer-selected
   (execute-kbd-macro (kbd "e c h o SPC o k"))
   (should (equal "ok" (mistty-send-and-capture-command-output (lambda () (execute-kbd-macro (kbd "RET"))))))))

(ert-deftest test-mistty-keystrokes-backspace ()
  (with-mistty-buffer-selected
   (execute-kbd-macro (kbd "e c h o SPC f o o DEL DEL DEL o k"))
   (should (equal "ok" (mistty-send-and-capture-command-output (lambda () (execute-kbd-macro (kbd "RET"))))))))

(ert-deftest test-mistty-reconcile-insert ()
  (with-mistty-buffer
   (mistty-run-command
    (insert "echo hello"))
   (should (equal "$ echo hello<>" (mistty-test-content)))
   (should (equal "hello" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-reconcile-delete ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo hello")
   (mistty-wait-for-output)
   (mistty-run-command
      (mistty-test-goto "hello")
      (delete-region (point) (+ 3 (point))))
   (should (equal "$ echo <>lo" (mistty-test-content)))
   (should (equal "lo" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-reconcile-delete-last-word ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo hello world")
   (mistty-wait-for-output)
   (mistty-run-command
    (save-excursion
      (mistty-test-goto " world")
      (delete-region (point) (point-max))))
   (should (equal "$ echo hello<>" (mistty-test-content)))
   (should (equal "hello" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-reconcile-replace ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo hello")
   (mistty-wait-for-output)
   (mistty-run-command
    (goto-char (point-min))
    (search-forward "hello")
    (replace-match "bonjour" nil t))
   (should (equal "$ echo bonjour<>" (mistty-test-content)))
   (should (equal "bonjour" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-prevent-deleting-prompt ()
  (with-mistty-buffer
   (should-error (backward-delete-char))
   (should-error (delete-region (point-min) (point-max)))))

(ert-deftest test-mistty-prevent-deleting-prompt-zsh ()
  (with-mistty-buffer-zsh
   (should-error (backward-delete-char))
   (should-error (delete-region (point-min) (point-max)))))

(ert-deftest test-mistty-change-before-prompt ()
  (with-mistty-buffer
   (let (beg end)
     (mistty-send-raw-string "echo hello")
     (mistty-wait-for-output)
     (setq beg (- (point) 5))
     (setq end (point))
     (mistty-send-raw-string "\n")
     (mistty-wait-for-output)
     (mistty-send-raw-string "echo world")  
     (mistty-wait-for-output)
     (should (equal "$ echo hello\nhello\n$ echo world<>" (mistty-test-content)))
     (mistty-run-command
      (delete-region beg end)
      (goto-char beg)
      (insert "bonjour"))
     ;; the modification is available and the point is after the insertion
     (should (equal "$ echo bonjour<>\nhello\n$ echo world" (mistty-test-content)))
     
     ;; the next command executes normally and doesn't revert the
     ;; modification, though it moves the point.
     (mistty-send-command)
     (mistty-wait-for-output)
     (should (equal "$ echo bonjour\nhello\n$ echo world\nworld" (mistty-test-content))))))

(ert-deftest test-mistty-send-command-because-at-prompt ()
  (with-mistty-buffer-selected
   (mistty-send-raw-string "echo hello")
   (should (equal "hello" (mistty-send-and-capture-command-output
                           (lambda ()
                             (execute-kbd-macro (kbd "RET"))))))
   (should (equal "$ echo hello\nhello" (mistty-test-content)))))

(ert-deftest test-mistty-send-newline-because-not-at-prompt ()
  (with-mistty-buffer-selected
   (mistty-send-raw-string "echo hello")
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (mistty-test-goto "hello"))
   (execute-kbd-macro (kbd "RET"))
   (should (equal "$ echo\n<>hello\nhello" (mistty-test-content)))))

(ert-deftest test-mistty-send-newline-because-not-at-prompt-multiline ()
  (with-mistty-buffer-selected
   (mistty-run-command
    (insert "echo hello\necho world"))
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (mistty-test-goto "hello"))
   (execute-kbd-macro (kbd "RET"))
   (should (equal "$ echo\n<>hello\necho world\nhello\nworld" (mistty-test-content)))))

(ert-deftest test-mistty-send-tab-to-complete  ()
  (with-mistty-buffer
   (mistty-send-raw-string "ech world")
   (mistty-wait-for-output)
   ;; Move the point before doing completion, to make sure that
   ;; mistty-send-if-at-prompt moves the pmark to the right position
   ;; before sending TAB.
   (mistty-run-command
    (goto-char (+ (point-min) 5)))
   (mistty-wait-for-output)
   (should (equal "$ ech<> world" (mistty-test-content)))
   (mistty-send-tab)
   (mistty-wait-for-output)
   (should (equal "$ echo<> world" (mistty-test-content)))))

(ert-deftest test-mistty-kill-term-buffer ()
  (let* ((buffer-and-proc (with-mistty-buffer
                           (cons mistty-term-buffer mistty-term-proc)))
         (term-buffer (car buffer-and-proc))
         (term-proc (cdr buffer-and-proc)))
    (mistty-wait-for-term-buffer-and-proc-to-die term-buffer term-proc 2)))

(ert-deftest test-mistty-term-buffer-exits ()
  (with-mistty-buffer
   (mistty-send-raw-string "exit\n")
   (mistty-wait-for-term-buffer-and-proc-to-die mistty-term-buffer mistty-term-proc 2)
   (should (string-suffix-p "finished\n" (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest test-mistty-scroll-with-long-command ()
  (with-mistty-buffer
   (let ((loop-command "for i in {0..49}; do echo line $i; done"))
     (mistty-send-raw-string loop-command)
     (mistty-wait-for-output)
     (should (equal (concat "$ " loop-command "<>") (mistty-test-content)))
     (should (equal (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 0 49) "\n")
                    (mistty-send-and-capture-command-output))))))

(ert-deftest test-mistty-scroll-with-many-commands ()
  (with-mistty-buffer
   (let ((loop-command "for i in {0..4}; do echo line $i; done"))
     (dotimes (_ 10)
       (mistty-send-raw-string loop-command)
       (mistty-wait-for-output)
       (should (equal (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 0 4) "\n")
                      (mistty-send-and-capture-command-output nil nil 'nopointer)))))))

(ert-deftest test-mistty-bracketed-paste ()
  (with-mistty-buffer
   (should (equal mistty-bracketed-paste t))
   (mistty-send-raw-string "read yesorno && echo answer: $yesorno\n")
   (mistty-wait-for-output)
   (should (equal mistty-bracketed-paste nil))
   (mistty-run-command (insert "no"))
   (should (equal "answer: no" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-bol ()
  (with-mistty-buffer
   (mistty-run-command
    (insert "echo hello")
    
    ;; Move the point after the prompt.
    (beginning-of-line)
    (should (equal (point) (mistty-test-goto "echo")))
    
    ;; Move to the real line start.
    (let ((inhibit-field-text-motion t))
      (beginning-of-line))
    (should (equal (point) (mistty-test-goto "$ echo hello"))))))

(ert-deftest test-mistty-bol-multiline ()
  (with-mistty-buffer
   (mistty-run-command
    (insert "echo \"hello\nworld\""))
   
   ;; Point is in the 2nd line, after world, and there's no prompt
   ;; on that line, so just go there.
   (beginning-of-line)
   (should (equal (point) (mistty--bol-pos-from (point))))))

(ert-deftest test-mistty-bol-outside-of-prompt ()
  (with-mistty-buffer
   (mistty-run-command
    (insert "echo one"))
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (insert "echo two"))
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (insert "echo three"))
   
   ;; (beginning-of-line) moves just after the prompt, even though
   ;; it's not the active prompt.
   (mistty-test-goto "two")
   (beginning-of-line)
   (should (equal
            (point) (save-excursion
                      (mistty-test-goto "echo two"))))))

(ert-deftest test-mistty-next-prompt ()
  (with-mistty-buffer
   (let (one two three current)
     (setq one (point))
     (mistty-run-command
      (insert "echo one"))
     (mistty-send-and-wait-for-prompt)
     (setq two (point))
     (mistty-run-command
      (insert "echo two"))
     (mistty-send-and-wait-for-prompt)
     (setq three (point))
     (mistty-run-command
      (insert "echo three"))
     (mistty-send-and-wait-for-prompt)
     (setq current (point))
     (mistty-run-command
      (insert "echo current"))

     (goto-char (point-min))
     (mistty-next-prompt 1)
     (should (equal one (point)))

     (mistty-next-prompt 1)
     (should (equal two (point)))

     (mistty-next-prompt 1)
     (should (equal three (point)))

     (mistty-next-prompt 1)
     (should (equal current (point)))

     (should-error (mistty-next-prompt 1))

     (goto-char (point-min))
     (mistty-next-prompt 2)
     (should (equal two (point)))
     
     (mistty-next-prompt 2)
     (should (equal current (point))))))

(ert-deftest test-mistty-previous-prompt ()
  (with-mistty-buffer
   (let (one three current)
     (setq one (point))
     (mistty-run-command
      (insert "echo one"))
     (mistty-send-and-wait-for-prompt)
     (mistty-run-command
      (insert "echo two"))
     (mistty-send-and-wait-for-prompt)
     (setq three (point))
     (mistty-run-command
      (insert "echo three"))
     (mistty-send-and-wait-for-prompt)
     (setq current (point))
     (mistty-run-command
      (insert "echo current"))

     (mistty-previous-prompt 1)
     (should (equal current (point)))
     
     (mistty-previous-prompt 1)
     (should (equal three (point)))

     (mistty-previous-prompt 2)
     (should (equal one (point)))

     (should-error (mistty-previous-prompt 1)))))

(ert-deftest test-mistty-dirtrack ()
  (with-mistty-buffer
   (mistty-send-raw-string "cd /\n")
   (mistty-send-and-wait-for-prompt)
   (should (equal "/" default-directory))
   (mistty-send-raw-string "cd ~\n")
   (mistty-send-and-wait-for-prompt)
   (should (equal (file-name-as-directory (getenv "HOME")) default-directory))))

(ert-deftest test-mistty-bash-backward-history-search ()
  (with-mistty-buffer-selected
   (mistty-run-command
    (insert "echo first"))
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (insert "echo second"))
   (mistty-send-and-wait-for-prompt)
   (mistty-run-command
    (insert "echo third"))
   (mistty-send-and-wait-for-prompt)
   (narrow-to-region (mistty--bol-pos-from (point)) (point-max))
   (mistty-send-raw-string "?\C-r")
   (mistty-wait-for-output)
   (should (equal "(reverse-i-search)`': ?<>" (mistty-test-content)))
   (execute-kbd-macro (kbd "e c"))
   (mistty-wait-for-output)
   (should (equal "(reverse-i-search)`ec': <>echo third" (mistty-test-content)))
   (execute-kbd-macro (kbd "o"))
   (mistty-wait-for-output)
   (should (equal "(reverse-i-search)`eco': echo s<>econd" (mistty-test-content)))
   (execute-kbd-macro (kbd "DEL"))
   (mistty-wait-for-output)
   (should (equal "(reverse-i-search)`ec': echo s<>econd" (mistty-test-content)))
   (execute-kbd-macro (kbd "RET"))
   (should (equal "second" (mistty-send-and-capture-command-output)))))

(ert-deftest test-mistty-distance-on-term ()
  (with-mistty-buffer-selected
   (mistty-send-raw-string "echo one two three four five six seven eight nine")
   (mistty-send-and-wait-for-prompt)

   (let ((two (mistty-test-goto "two"))
         (three (mistty-test-goto "three"))
         (four (mistty-test-goto "four")))
     (should (equal 4 (mistty--distance-on-term two three)))
     (should (equal 6 (mistty--distance-on-term three four)))
     (should (equal -4 (mistty--distance-on-term three two))))))

(ert-deftest test-mistty-distance-on-term-with-hard-newlines ()
  (with-mistty-buffer
   (mistty--set-process-window-size 20 20)

   (mistty-send-raw-string "echo one two three four five six seven eight nine")
   (mistty-wait-for-output)
   (mistty-send-and-wait-for-prompt)

   (should (equal (concat "$ echo one two three\n"
                          " four five six seven\n"
                          " eight nine\n"
                          "one two three four f\n"
                          "ive six seven eight\n"
                          "nine")
                  (mistty-test-content nil nil 'nopointer)))

   (let ((one (mistty-test-goto "one"))
         (six (mistty-test-goto "six"))
         (end (mistty-test-goto-after "nine\n")))
     (should (equal 24 (mistty--distance-on-term one six)))
     (should (equal -24 (mistty--distance-on-term six one)))
     (should (equal 45 (mistty--distance-on-term one end)))
     (should (equal -45 (mistty--distance-on-term end one))))))

(ert-deftest test-mistty-insert-long-prompt ()
  (with-mistty-buffer
   (mistty--set-process-window-size 20 20)

   (mistty-run-command
    (insert "echo one two three four five six seven eight nine"))
   (while (length= (mistty-test-content) 0)
     (accept-process-output mistty-term-proc 0 500 t))
   (should (equal "$ echo one two three\n four five six seven\n eight nine<>"
                  (mistty-test-content)))))

(ert-deftest test-mistty-keep-sync-marker-on-long-prompt ()
  (with-mistty-buffer
   (mistty--set-process-window-size 20 20)

   (mistty-run-command
    (insert "echo one two three four five six seven eight nine"))
   (while (length= (mistty-test-content) 0)
     (accept-process-output mistty-term-proc 0 500 t))

   ;; make sure that the newlines didn't confuse the sync marker
   (should (equal (marker-position mistty-sync-marker) (point-min)))
   (should (equal (marker-position mistty-cmd-start-marker) (mistty-test-goto "echo one")))))

(ert-deftest test-mistty-keep-track-pointer-on-long-prompt ()
  (with-mistty-buffer
   (mistty--set-process-window-size 20 20)

   (mistty-run-command
    (insert "echo one two three four five six seven eight nine"))
   (while (length= (mistty-test-content) 0)
     (accept-process-output mistty-term-proc 0 500 t))

   ;; make sure that the newlines don't confuse mistty-post-command
   ;; moving the cursor.
   (dolist (count '("three" "nine" "four"))
     (let ((goal-pos))
       (mistty-pre-command)
       (setq goal-pos (mistty-test-goto count))
       (mistty-post-command)
       (mistty-wait-for-output)
       (should (equal (mistty-pmark) goal-pos))))))

(ert-deftest test-mistty-enter-fullscreen ()
  (with-mistty-buffer-selected
    (let ((bufname (buffer-name))
          (work-buffer mistty-work-buffer)
          (term-buffer mistty-term-buffer)
          (proc mistty-term-proc))
      
      (execute-kbd-macro (kbd "v i RET"))
      (while (not (buffer-local-value 'mistty-fullscreen work-buffer))
        (accept-process-output proc 0 500 t))
      (should (eq mistty-term-buffer (window-buffer (selected-window))))
      (should (equal (concat bufname " scrollback") (buffer-name work-buffer)))
      (should (equal bufname (buffer-name term-buffer)))
      
      (execute-kbd-macro (kbd ": q ! RET"))
      (while (buffer-local-value 'mistty-fullscreen work-buffer)
        (accept-process-output proc 0 500 t))
      (should (eq mistty-work-buffer (window-buffer (selected-window))))
      (should (equal (concat " mistty tty " bufname) (buffer-name term-buffer)))
      (should (equal bufname (buffer-name work-buffer))))))

(ert-deftest test-mistty-enter-fullscreen-alternative-code ()
  (with-mistty-buffer-selected
    (let ((work-buffer mistty-work-buffer)
          (proc mistty-term-proc))

      (mistty-send-raw-string "printf '\\e[?47hPress ENTER: ' && read && printf '\\e[?47lfullscreen off\n'")
      (mistty-send-command)
      (while (not (buffer-local-value 'mistty-fullscreen work-buffer))
        (accept-process-output proc 0 500 t))
      (should (eq mistty-term-buffer (window-buffer (selected-window))))

      (execute-kbd-macro (kbd "RET"))
      (while (buffer-local-value 'mistty-fullscreen work-buffer)
        (accept-process-output proc 0 500 t))
      (should (eq mistty-work-buffer (window-buffer (selected-window)))))))

(ert-deftest test-mistty-kill-fullscreen-buffer-kills-scrollback ()
  (with-mistty-buffer-selected
    (let ((work-buffer mistty-work-buffer)
          (proc mistty-term-proc))
      (execute-kbd-macro (kbd "v i RET"))
      (while (not (buffer-local-value 'mistty-fullscreen mistty-work-buffer))
        (accept-process-output mistty-term-proc 0 500 t))

      (kill-buffer mistty-term-buffer)
      (mistty-wait-for-term-buffer-and-proc-to-die work-buffer proc 2))))

(ert-deftest test-mistty-proc-dies-during-fullscreen ()
  (with-mistty-buffer-selected
    (let ((bufname (buffer-name))
          (work-buffer mistty-work-buffer)
          (term-buffer mistty-term-buffer)
          (proc mistty-term-proc))
      (execute-kbd-macro (kbd "v i RET"))
      (while (not (buffer-local-value 'mistty-fullscreen mistty-work-buffer))
        (accept-process-output proc 0 500 t))

      (signal-process proc 'SIGILL)

      (mistty-wait-for-term-buffer-and-proc-to-die term-buffer proc 2)

      (should (buffer-live-p work-buffer))
      (should (eq work-buffer (window-buffer (selected-window))))
      (should (string-match "illegal instruction" (buffer-substring-no-properties (point-min) (point-max))))
      (should (equal bufname (buffer-name work-buffer)))
      (should (not (buffer-local-value 'mistty-fullscreen mistty-work-buffer))))))

(ert-deftest test-mistty-collect-modifications-delete-after-replace ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (delete-region 6 9)
    (goto-char 6)
    (insert "new-value")
    
    (delete-region 18 21)

    (should (equal "$ abcnew-valueghimno<<end>>" (buffer-substring-no-properties (point-min) (point-max))))

    ;; The deletion is reported first, even though it was applied
    ;; last. If we did the reverse and a newline was inserted in the
    ;; middle of new-value, the deletion would not apply to the right
    ;; region.
    (should (equal '((12 "" 3) (6 "new-value" 3)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-delete-at-end ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (delete-region 6 (point-max))
    
    (should (equal "$ abc" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((6 "" -1)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-insert-then-delete-at-end ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (delete-region 6 (point-max))
    (goto-char 6)
    (insert "new-value")
    
    (should (equal "$ abcnew-value" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((6 "new-value" -1)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-insert-skip-then-delete-at-end ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (delete-region 15 (point-max))
    (delete-region 9 12)
    (goto-char 6)
    (insert "new-value")
    
    (should (equal "$ abcnew-valuedefjkl" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((15 "" -1) (9 "" 3) (6 "new-value" 0)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-inserts ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (goto-char 12)
    (insert "NEW")
    
    (goto-char 9)
    (insert "NEW")
    
    (goto-char 6)
    (insert "NEW")
    
    (should (equal "$ abcNEWdefNEWghiNEWjklmno<<end>>" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((12 "NEW" 0) (9 "NEW" 0) (6 "NEW" 0)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-insert-at-end ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdef")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (goto-char 9)
    (insert "NEW")
    
    (should (equal "$ abcdefNEW" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((9 "NEW" 0)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-collect-modifications-replaces ()
  (ert-with-test-buffer ()
    (let ((ov (make-overlay 1 1 nil nil 'rear-advance)))
    (insert "$ ")
    (move-overlay ov (point) (point-max-marker))
    (setq mistty-cmd-start-marker (point))
    
    (insert "abcdefghijklmno<<end>>")
    (overlay-put ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put ov 'insert-behind-hooks (list #'mistty--modification-hook))

    (goto-char 12)
    (delete-region 12 15)
    (insert "NEW")
    
    (goto-char 6)
    (delete-region 6 9)
    (insert "NEW")
    
    (should (equal "$ abcNEWghiNEWmno<<end>>" (buffer-substring-no-properties (point-min) (point-max))))

    (should (equal '((12 "NEW" 3) (6 "NEW" 3)) (mistty--collect-modifications))))))

(ert-deftest test-mistty-osc ()
  (with-mistty-buffer
    (let ((osc-list))
      (with-current-buffer mistty-term-buffer
        (add-hook 'mistty-osc-hook
                  (lambda (seq)
                    (push seq osc-list))
                  nil t))
      (mistty-send-raw-string "printf '\\e]8;;http://www.example.com\\aSome OSC\\e]8;;\\a!\\n'")
      (should (equal "Some OSC!" (mistty-send-and-capture-command-output)))
      (should (equal '("8;;http://www.example.com" "8;;") (nreverse osc-list))))))

(ert-deftest test-mistty-osc-standard-end ()
  (with-mistty-buffer
    (let ((osc-list))
      (with-current-buffer mistty-term-buffer
        (add-hook 'mistty-osc-hook
                  (lambda (seq)
                    (push seq osc-list))
                  nil t))
      (mistty-send-raw-string "printf '\\e]8;;http://www.example.com\\e\\\\Some OSC\\e]8;;\\e\\\\!\\n'")
      (should (equal "Some OSC!" (mistty-send-and-capture-command-output)))
      (should (equal '("8;;http://www.example.com" "8;;") (nreverse osc-list))))))

(ert-deftest test-mistty-osc-add-text-properties ()
  (with-mistty-buffer
   (with-current-buffer mistty-term-buffer
     (let ((start nil)
           (test-value nil))
       (add-hook 'mistty-osc-hook
                 (lambda (seq)
                   (if (length> seq 0)
                       (setq test-value seq
                             start (point))
                     (put-text-property start (point) 'mistty-test test-value)))
                 nil t)))
   (mistty-send-raw-string "printf 'abc \\e]foobar\\adef\\e]\\a ghi\\n'")
   (should (equal "abc def ghi" (mistty-send-and-capture-command-output)))
   (search-backward "def")
   (should (equal `((,(1- (point)) ,(+ 2 (point)) (mistty-test "foobar")))
                  (mistty-merge-intervals
                   (mistty-filter-intervals
                    (object-intervals (current-buffer))
                    '(mistty-test)))))))

(ert-deftest test-mistty-reset ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo one")
   (mistty-send-and-wait-for-prompt)
   (mistty-send-raw-string "printf '\\ec'")
   (mistty-send-and-wait-for-prompt)
   (mistty-send-raw-string "echo two")
   (mistty-send-and-wait-for-prompt)
   (should (equal "$ echo one\none\n$ printf '\\ec'\n$ echo two\ntwo" (mistty-test-content nil nil 'nopointer)))))

(ert-deftest test-mistty-clear-screen ()
  (with-mistty-buffer
   (mistty-send-raw-string "echo one")
   (mistty-send-and-wait-for-prompt)
   (mistty-send-raw-string "printf '\\e[2J'")
   (mistty-send-and-wait-for-prompt)
   (mistty-send-raw-string "echo two")
   (mistty-send-and-wait-for-prompt)
   (should (equal "$ echo one\none\n$ printf '\\e[2J'\n$ echo two\ntwo" (mistty-test-content nil nil 'nopointer)))))
   
(defun mistty-test-goto (str)
  "Search for STR, got to its beginning and return that position."
  (mistty-test-goto-after str)
  (goto-char (match-beginning 0)))

(defun mistty-test-goto-after (str)
  "Search for STR, got to its end and return that position."
  (goto-char (point-min))
  (search-forward str))

(defun mistty-test-setup (shell)
  (cond
   ((eq shell 'bash)
    (mistty--exec mistty-test-bash-exe "--noprofile" "--norc" "-i"))
   ((eq shell 'zsh)
    (mistty--exec mistty-test-zsh-exe "-i" "--no-rcs"))
   (t (error "Unsupported shell %s" shell)))
  (while (eq (point-min) (point-max))
    (accept-process-output mistty-term-proc 0 100 t))
  (mistty-send-raw-string (concat "PS1='" mistty-test-prompt "'"))
  (mistty-wait-for-output)
  (narrow-to-region (mistty-send-and-wait-for-prompt) (point-max)))

(defun mistty-wait-for-output ()
  "Wait for process output, which should be short and immediate."
  (unless (accept-process-output mistty-term-proc 0 500 t)
    (error "no output")))

(defun mistty-send-and-capture-command-output (&optional send-command-func narrow nopointer)
  "Send the current commanhd line with SEND-COMMAND-FUNC and return its output.

This function sends RET to the process, then waits for the next
prompt to appear. Once the prompt has appeared, it captures
everything between the two prompts, return it, and narrow the
buffer to a new region at the beginning of the new prompt."
  (let ((first-prompt-end (point))
        output-start next-prompt-start output)
    (setq next-prompt-start (mistty-send-and-wait-for-prompt send-command-func))
    (setq output-start
          (save-excursion
            (goto-char first-prompt-end)
            ;; If BACKSPACE was used, there could be leftover spaces
            ;; at the end of the line when the tty overwrites intead
            ;; of deleting.
            (goto-char (line-end-position))
            (1+ (point))))
    (setq output (mistty-test-content output-start next-prompt-start nopointer))
    (when narrow
      (narrow-to-region next-prompt-start (point-max)))
    output))

(defun mistty-send-and-wait-for-prompt (&optional send-command-func)
  "Send the current command line and wait for a prompt to appear.

Puts the point at the end of the prompt and return the position
of the beginning of the prompt."
  (let ((before-send (point)))
    (funcall (or send-command-func #'mistty-send-command))
    (while (not (save-excursion
                  (goto-char before-send)
                  (search-forward-regexp (concat "^" (regexp-quote mistty-test-prompt)) nil 'noerror)))
      (unless (accept-process-output mistty-term-proc 0 500 t)
        (error "no output >>%s<<" (buffer-substring-no-properties before-send (point-max)))))
    (match-beginning 0)))

(defun mistty-test-content  (&optional start end nopointer)
  (interactive)
  (let* ((start (or start (point-min)))
         (end (or end (point-max)))
         (output (buffer-substring-no-properties start end))
         (p (- (point) start))
         (length (- end start)))
    (when (and (not nopointer) (>= p 0) (<= p length))
      (setq output (concat (substring output 0 p) "<>" (substring output p))))
    (setq output (replace-regexp-in-string "\\$ \\(<>\\)?\n?$" "" output))
    (setq output (replace-regexp-in-string "[ \t\n]*$" "" output))
    output))

(defun mistty-wait-for-term-buffer-and-proc-to-die (buf proc deadline)
  (should (not (null buf)))
  (should (not (null proc)))
  (let ((tstart (current-time)))
    (while (or (process-live-p proc) (buffer-live-p buf))
      (accept-process-output proc 0 100)
      (when (> (float-time (time-subtract (current-time) tstart)) deadline)
        (cond ((process-live-p proc)
               (error "Process %s didn't die. Status: %s" proc (process-status proc)))
              ((buffer-live-p buf)
               (error "Buffer %s wasn't killed." buf))
              (t (error "Something else went wrong.")))))))

(defun mistty-filter-plist (options allowed)
  "Filter a symbol and values list OPTIONS to online include ALLOWED symbols.

For example, filtering (:key value :other-key value) with allowed
list of (:key) will return (:key value)."
  (let ((filtered-list))
    (dolist (key allowed)
      (when (plist-member options key)
        (setq filtered-list
              (plist-put filtered-list key (plist-get options key)))))
    filtered-list))

(defun mistty-filter-intervals (intervals allowed)
  (delq nil (mapcar
             (lambda (c)
               (pcase c
                 (`(,beg ,end ,props)
                  (let ((filtered (mistty-filter-plist props allowed)))
                    (when filtered
                      `(,beg ,end ,filtered))))))
             intervals)))
  
(defun mistty-merge-intervals (intervals)
  (let ((c intervals))
    (while c
      (pcase c
        ((and `((,beg1 ,end1 ,props1) (,beg2 ,end2 ,props2) . ,tail)
              (guard (and (= end1 beg2)
                          (equal props1 props2))))
         (setcar c `(,beg1 ,end2 ,props1))
         (setcdr c tail))
        (_ (setq c (cdr c)))))
    intervals))