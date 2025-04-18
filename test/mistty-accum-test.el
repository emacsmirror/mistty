;;; Tests mistty-accum.el -*- lexical-binding: t -*-

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

(require 'mistty-accum)
(require 'mistty-accum-macros)
(require 'ert)
(require 'ert-x)

(require 'mistty-testing)

(ert-deftest mistty-accum-smoke ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (process-send-string proc "hello, ")
      (process-send-string proc "world!")

      (while (accept-process-output nil 0.1))

      (should (equal "hello, world!"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-processor-remove-seq ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor
       accum '(seq ESC ?=) #'ignore)

      (funcall accum proc "foo\e=bar")
      (should (equal "foobar"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-processor-forward-data ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor
       accum '(seq ESC ?=)
       (lambda (ctx str)
         (mistty--accum-ctx-push-down ctx str)))

      (funcall accum proc "foo\e=bar")
      (should (equal "foo\e=bar"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-processor-push-down-data ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor
       accum '(seq ESC ?=)
       (lambda (ctx _)
         (mistty--accum-ctx-push-down ctx "-")
         (mistty--accum-ctx-push-down ctx "-")))

      (funcall accum proc "foo\e=bar")
      (should (equal "foo--bar"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-processor-flush ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor
       accum '(seq ESC ?=)
       (lambda (ctx _)
         (mistty--accum-ctx-flush ctx)
         (should (equal "foo"
                        (mistty-test-proc-buffer-string proc)))))

      (funcall accum proc "foo\e=bar")
      (should (equal "foobar"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-processor-flush-and-push-down ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor
       accum '(seq ESC ?=)
       (lambda (ctx data)
         ;; Anything pushed before flush is visible afterwards.
         (mistty--accum-ctx-push-down ctx "-")
         (mistty--accum-ctx-flush ctx)
         (should (equal "foo-"
                        (mistty-test-proc-buffer-string proc)))

         ;; There can be more push-down and flushes.
         (mistty--accum-ctx-push-down ctx "-")
         (mistty--accum-ctx-push-down ctx "-")
         (mistty--accum-ctx-flush ctx)
         (should (equal "foo---"
                        (mistty-test-proc-buffer-string proc)))

         ;; Anything pushed after the flush is not visible
         ;; until later.
         (mistty--accum-ctx-push-down ctx "-")
         (should (equal "foo---"
                        (mistty-test-proc-buffer-string proc)))))

      (funcall accum proc "foo\e=bar")
      (should (equal "foo----bar"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-post-processor ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-post-processor
       accum
       (lambda ()
         (upcase-region (point-min) (point-max))))

      (funcall accum proc "foobar")

      (should (equal "FOOBAR"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-post-processor-and-processors ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-post-processor
       accum
       (lambda ()
         (upcase-region (point-min) (point-max))))

      (mistty--accum-add-processor
       accum '(seq ESC ?=)
       (lambda (ctx _)
         (mistty--accum-ctx-push-down ctx "-foo-")
         (mistty--accum-ctx-flush ctx)
         ;; The post-process hasn't been called on the current data
         ;; yet. It's only called at the end.
         (should (equal "FIRST-before-foo-"
                        (mistty-test-proc-buffer-string proc)))))

      (funcall accum proc "first-")
      (funcall accum proc "before\e=after")

      (should (equal "FIRST-BEFORE-FOO-AFTER"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-post-processor-called-in-order ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-post-processor
       accum (lambda () (insert "1")))

      (mistty--accum-add-post-processor
       accum (lambda () (insert "2")))

      (funcall accum proc "foo")

      (should (equal "foo12"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-around ()
  (mistty-with-test-process (proc)
    (let* ((calls nil)
           (real-process-filter (process-filter proc))
           (accum (mistty--make-accumulator (lambda (proc data)
                                              (push 'process-filter calls)
                                              (funcall real-process-filter proc data)))))
      (set-process-filter proc accum)

      (funcall accum proc "baa")
      (should (equal '(process-filter) (reverse calls)))
      (setq calls nil)

      (mistty--accum-add-around-process-filter
       accum
       (lambda (func)
         (push 'around-1 calls)
         (funcall func)))

      (funcall accum proc "baa")
      (should (equal '(around-1 process-filter) (reverse calls)))
      (setq calls nil)

      (mistty--accum-add-around-process-filter
       accum
       (lambda (func)
         (push 'around-2 calls)
         (funcall func)))

      (funcall accum proc "baa")
      (should (equal '(around-2 around-1 process-filter)
                     (reverse calls)))
      (setq calls nil))))

(ert-deftest mistty-accum-around-and-processors ()
  (mistty-with-test-process (proc)
    (let* ((calls nil)
           (accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (mistty--accum-add-around-process-filter
       accum
       (lambda (func)
         (push 'around calls)
         (funcall func)))

      (mistty--accum-add-processor
       accum '(seq "aa")
       (lambda (ctx str)
         (mistty--accum-ctx-push-down ctx "oo")

         ;; around should be called from flush
         (let ((call-count (length calls)))
           (mistty--accum-ctx-flush ctx)
           (should (equal (1+ call-count) (length calls))))))

      (funcall accum proc "baa, baa, black sheep")

      ;; Around should be called once for each "aa" and once at the
      ;; end.
      (should (equal 3 (length calls)))

      (should (equal "boo, boo, black sheep"
                     (mistty-test-proc-buffer-string proc))))))

(ert-deftest mistty-accum-hold-back ()
  (mistty-with-test-process (proc)
    (let* ((capture nil) ;; captured data in reverse order
           (accum (mistty--make-accumulator
                   (lambda (proc data)
                     (push data capture)))))
      (set-process-filter proc accum)

      (mistty--accum-add-processor-1
       accum (mistty--accum-make-processor
              :regexp "\e\\[[0-9;]*J"
              :hold-back-regexps '("\e" "\e\\[[0-9;]*")
              :func (lambda (ctx str)
                      (mistty--accum-ctx-push-down ctx str))))
      (funcall accum proc "foo\e")
      (funcall accum proc "[")
      (funcall accum proc "2")
      (funcall accum proc "J")
      (funcall accum proc "-\e[")
      (funcall accum proc "Jbar")
      (should (equal '("foo" "\e[2J" "-" "\e[Jbar")
                     (reverse capture))))))

(ert-deftest mistty--accum-build-hold-back ()
  ;; test string
  (should (equal '("h" "he" "hel" "hell")
                 (mistty--accum-build-hold-back "hello")))

  ;; test seq
  (should (equal
           '("\e")
           (mistty--accum-build-hold-back
            '(seq ?\e ?\=))))

  ;; test star
  (should (equal
           '("\e" "\e[0-9;]*")
           (mistty--accum-build-hold-back
            '(seq ?\e (* (char "0-9;")) ?\J))))

  ;; test optional and plus
  (should (equal
           '("\e" "\e[0-9]+" "\e[0-9]+;" "\e[0-9]+;[0-9]+")
           (mistty--accum-build-hold-back
            '(seq ?\e (? (seq (+ (char "0-9")) ?\; (+ (char "0-9")))) ?H))))

  ;; test seq in star
  (should (equal
           '("\e" "\e\\(?:[0-9];\\)*" "\e\\(?:[0-9];\\)*[0-9]")
           (mistty--accum-build-hold-back
            '(seq ?\e (* (seq (char "0-9") ?\;)) ?H))))

  ;; test or
  (should (equal
           '("\e" "\e]" "\e][a-z]*" "\e][a-z]*\e")
           (mistty--accum-build-hold-back
            '(seq ?\e ?\] (* (char "a-z")) (or ?\a (seq ?\e ?\\))))))

  ;; test or followed by something
  (should (equal
           '("\e" "\e]" "\e][a-z]*" "\e][a-z]*\e"
             "\e][a-z]*\\(?:\a\\|\e\\\\\\)")
           (mistty--accum-build-hold-back
            '(seq ?\e ?\] (* (char "a-z")) (or ?\a (seq ?\e ?\\)) ?.)))))

(ert-deftest mistty--accum-build-hold-back-csi-to-regexp ()
  ;; CSI includes [, which must be quoted properly
  (should (equal '("\e" "\e\\[" "\e\\[[0-9]*")
                 (mistty--accum-build-hold-back
                  (mistty--accum-expand-shortcuts
                   '(seq CSI Ps ?J))))))

(defun mistty-test-expand-shortcuts (tree)
  (rx-to-string (mistty--accum-expand-shortcuts tree) 'no-group))

(ert-deftest mistty--accum-expand-shortcuts-single ()
  (should (equal
           "\e\\["
           (mistty-test-expand-shortcuts 'CSI)))
  (should (equal
           "\e]"
           (mistty-test-expand-shortcuts 'OSC)))
  (should (equal
           "[0-9]*"
           (mistty-test-expand-shortcuts 'Ps)))
  (should (equal
           "[0-9;]*"
           (mistty-test-expand-shortcuts 'Pm)))
  (should (equal
           "\a\\|\e\\\\"
           (mistty-test-expand-shortcuts 'ST))))

(ert-deftest mistty--accum-expand-shortcuts-recursive ()
  (should (equal "\e\\[[0-9]*J"
                 (mistty-test-expand-shortcuts '(seq CSI Ps ?J))))

  (should (equal "\e][^\0-\7\x0e-\x1f\x7f]*\\(?:\a\\|\e\\\\\\)"
                 (mistty-test-expand-shortcuts '(seq OSC Pt ST)))))

(ert-deftest mistty-accum-test-split-incomplete-chars ()
  (ert-with-test-buffer ()
    (should (equal '("foo" . nil)
                   (mistty--split-incomplete-chars "foo")))

    (should (equal '("foo bar abcde\342\224\200" . nil)
                   (mistty--split-incomplete-chars
                    "foo bar abcde\342\224\200")))

    (should (equal '("foo bar abcde\342\224\200" . "\342\224")
                   (mistty--split-incomplete-chars
                    "foo bar abcde\342\224\200\342\224")))))

(ert-deftest mistty-accum-test-join-incomplete-chars ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc))))
      (set-process-filter proc accum)

      (funcall accum proc "|\342\224\200")
      (funcall accum proc "\342") (funcall accum proc "\224\200")
      (funcall accum proc "\342\224") (funcall accum proc "\200")
      (funcall accum proc "\342\224\200|")

      (should (equal "|────|"
                     (decode-coding-string
                      (mistty-test-proc-buffer-string proc)
                      'utf-8))))))

(ert-deftest mistty-accum-processor-look-back ()
  (mistty-with-test-process (proc)
    (let ((accum (mistty--make-accumulator (process-filter proc)))
          (lookbacks nil))
      (set-process-filter proc accum)

      ;; Change each aa with oo and remember what the lookback buffer
      ;; looked before and after adding the oo.
      (mistty--accum-add-processor
       accum '(seq ?a ?a)
       (lambda (ctx _)
         (push (mistty--accum-ctx-look-back ctx) lookbacks)
         (mistty--accum-ctx-push-down ctx "oo")
         (push (mistty--accum-ctx-look-back ctx) lookbacks)))

      ;; Force a flush at every comma. This should have no impact.
      (mistty--accum-add-processor
       accum ?,
       (lambda (ctx _)
         (mistty--accum-ctx-push-down ctx ",")
         (mistty--accum-ctx-flush ctx)))

      (funcall accum proc ">")
      (funcall accum proc "baa, baa, baa!")

      (should (equal '(">b"        ; first baa
                       ">boo"      ; first baa, oo was pushed
                       ">boo, b"   ; second baa
                       "boo, boo"  ; second baa, oo was pushed,
                       ", boo, b"  ; third baa
                       "boo, boo"  ; third baa, oo was pushed
                       )
                     (nreverse lookbacks))))))
