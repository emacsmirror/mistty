;;; mistty-term.el --- Extensions for term.el for MisTTY -*- lexical-binding: t -*-

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
;; This file collects helpers for mistty.el that deal with the
;; terminal buffer.

(require 'pcase)
(require 'subr-x)
(eval-when-compile
  (require 'cl-lib))

(require 'mistty-util)
(require 'mistty-log)
(require 'mistty-accum)
(eval-when-compile
  (require 'mistty-accum-macros))
(require 'mistty-kbd)
(require 'mistty-raw)

;;; Code:

(autoload 'mistty-osc7 "mistty-osc7")
(autoload 'mistty-osc-query-color "mistty-osc-colors")
(autoload 'ansi-osc-window-title-handler "ansi-osc")
(autoload 'ansi-osc-hyperlink-handler "ansi-osc")

(defcustom mistty-osc-handlers
  '(
    ;; not using ansi-osc-directory-tracker because it doesn't decode
    ;; the coding system of the path after percent-decoding it.
    ;; TODO: propose a fix for ansi-osc
    ("7" . mistty-osc7)

    ;; These handlers are reasonably compatibly with MisTTY OSC. This
    ;; isn't necessary going to be the case for all such handlers.
    ("0" . ansi-osc-window-title-handler)
    ("2" . ansi-osc-window-title-handler)
    ("8" . ansi-osc-hyperlink-handler)

    ;; Allow querying foreground and background color. While OSC 10/11
    ;; normally supports changing color, this isn't supported here.
    ("10" . mistty-osc-query-color)
    ("11" . mistty-osc-query-color)
    ("133" . mistty-osc133))
  "Hook run when unknown OSC sequences have been received.

This hook is run on the terminal buffer. It is passed the OSC code as
a string and the content of OSC sequence - everything between OSC (ESC
]) and ST (ESC \\ or \\a) and may choose to handle them.

The current buffer is a terminal buffer. The hook is allowed to
modify it, to add text properties, for example. In such case,
consider using `mistty-register-text-properties'.

Most handlers written for the ansi-osc package (Emacs 29) should
work here as well.

If you add here a handler that sets a buffer-local variable,
consider adding that variable to `mistty-variables-to-copy' so
that its value is available in the main MisTTY buffer, not just
the terminal buffer."
  :group 'mistty
  :type '(alist :key-type string :value-type function))

(defcustom mistty-set-EMACS nil
  "Whether the EMACS env variable should be set, for Bash 4.3 and older.

You only need to set this if:
 - you're stuck using a very old version of Bash (4.3 or older)
 - you don't want to set up directory tracking using OSC7
   as described in the manual

When set, MisTTY sets the EMACS env variable, which Bash 4.3 and
older check to decide whether to send out directory tracking
information. (Newer version check INSIDE_EMACS instead.)

As this is usually host-specific, it can be set as a
connection-local variable. This might be useful when connecting
with TRAMP to hosts or docker instances that use a very old
version of Bash that you don't want to configure.

For example:

  (connection-local-set-profile-variables
   \\='profile-old-bash
   \\='((mistty-set-EMACS . t)
     (mistty-shell-command . (\"/bin/bash\" \"-i\"))))

  (connection-local-set-profiles \\='(:machine \"oldhost.example.com\")
   \\='profile-old-bash)
  (connection-local-set-profiles \\='(:protocol \"docker\")
   \\='profile-old-bash)"
  :group 'mistty
  :type 'boolean)

(defcustom mistty-multi-line-continue-prompts
  '("^    *\\.\\.\\.: " ; ipython
    )
  "Regexp used to identify multi-line command prompts.

These regexps identifies prompts that tell the user that they can
type more, while still allowing them to edit what's above. MisTTY
uses these regexps to identify sections of texts it should ignore
when editing.

Note that bash \"> \" is not a continuation prompt, with this
definition, because it doesn't allow editing what's above."
  :group 'mistty
  :type '(list regexp))

(defconst mistty-right-str "\eOC"
  "Sequence to send to the process when the rightarrow is pressed.")

(defconst mistty-left-str "\eOD"
  "Sequence to send to the process when the left arrow is pressed.")

(defconst mistty-up-str "\eOA"
  "Sequence to send to the process when the uparrow is pressed.")

(defconst mistty-down-str "\eOB"
  "Sequence to send to the process when the left arrow is pressed.")

(defvar-local mistty-bracketed-paste nil
  "Whether bracketed paste is enabled in the terminal.

This variable evaluates to true when bracketed paste is turned on
by the command that controls, to false otherwise.

This variable is available in both the work and term buffers.")

(defvar-local mistty--term-properties-to-add-alist nil
  "An alist of id to text properties to add to the term buffer.

This variable associates arbitrary symbols to property lists. It
is set by `mistty-register-text-properties' and read whenever
text is written to the terminal.

This variable is available in the work buffer.")

(defvar-local mistty--original-cursor nil
  "The local value `cursor-type' had before it was hidden.

Will be nil even though the cursor is hidden if the cursor had no
local value. `mistty--show-cursor' then restores the global
value.

Used in `mistty--hide-cursor' and `mistty--show-cursor'.")

(defvar-local mistty--prompt-cell nil
  "A `mistty--prompt-cell' instance.

This is used to share prompts between the work and term buffers. This is
accessible from either buffer.

Always access it through the places `mistty--prompt'
`mistty--prompt-archive' and `mistty--prompt-counter'.")

(defconst mistty--prompt-regexp
  "[^[:alnum:][:cntrl:][:blank:]][[:blank:]]$"
  "Regexp used to identify prompts.

New, empty lines that might be prompts are evaluated against this
regexp. This regexp should match something that looks like the
end of a prompt with no commands.")

(cl-defstruct (mistty--prompt-cell
               (:constructor mistty--make-prompt-cell
                             (&aux (counter 0))))
  current
  archive
  counter)

;; A detected prompt.
;;
;; This datastructure is shared between the work and term buffer and
;; uses scrollines as units.
(cl-defstruct (mistty--prompt
               (:constructor mistty--make-prompt
                             (source start &optional end &key text
                                     &aux (input-id
                                           (progn
                                             (cl-incf (mistty--prompt-cell-counter
                                                       mistty--prompt-cell)))))))
  input-id

  ;; prompt source:
  ;;  - regexp
  ;;  - bracketed paste
  source

  ;; Non-nil once the prompt has been accepted by MisTTY
  realized

  ;; Start scrolline. Shouldn't be nil.
  start

  ;; End scrolline, or nil if prompt is open-ended.
  ;;
  ;; This is the first scrolline on which the prompt is *not* present, so
  ;; a single-line prompt starting at 10 would end at 11.
  end

  ;; Text of the prompt, used when source=regexp.
  text

  ;; Position of the start of the user input, if known.
  ;; This is a (cons scrolline column).
  user-input-start)

(defun mistty--prompt ()
  "Get the value of the current `mistty--prompt' struct or nil."
  (when-let* ((cell mistty--prompt-cell))
    (mistty--prompt-cell-current cell)))

(defun mistty--prompt-archive ()
  "Get the list of archived `mistty--prompt' structs."
  (when-let* ((cell mistty--prompt-cell))
    (mistty--prompt-cell-archive cell)))

(defun mistty--prompt-counter ()
  "Get the number of prompt instances created in this buffer."
  (when-let* ((cell mistty--prompt-cell))
    (mistty--prompt-cell-counter cell)))

(gv-define-setter mistty--prompt (val)
  "Sets the value of the current `mistty--prompt' struct.

The old value, if any, is pushed into `mistty--prompt-archive'."
  `(progn
     (when-let* ((old (mistty--prompt-cell-current mistty--prompt-cell)))
       (push old (mistty--prompt-cell-archive mistty--prompt-cell)))
     (setf (mistty--prompt-cell-current mistty--prompt-cell) ,val)))

(gv-define-setter mistty--prompt-archive (val)
  "Sets the value of `mistty--prompt-archive'."
  `(setf (mistty--prompt-cell-archive mistty--prompt-cell) ,val))

(defun mistty--prompt-contains (prompt scrolline)
  "Return non-nil if SCROLLINE is inside of PROMPT."
  (and (>= scrolline (mistty--prompt-start prompt))
       (or (null (mistty--prompt-end prompt))
           (< scrolline (mistty--prompt-end prompt)))))

(defun mistty--emulate-terminal (proc str)
  "Handle process output as a terminal would.

This function accepts output from PROC included into STR and forwards
them to the virtual terminal."
  (mistty-raw--process-filter proc str))

(defun mistty--add-osc-detection (accum)
  "Handle OSC code in ACCUM.

Known OSC codes are passed down to handlers registered in
`mistty-osc-handlers'."
  (mistty--accum-add-processor-lambda accum
      (ctx '(seq OSC (let code Ps) ?\; (let text Pt) ST))
   (when-let* ((handler (cdr (assoc-string code mistty-osc-handlers))))
     (mistty--accum-ctx-flush ctx)
     (let ((inhibit-modification-hooks t)
           (inhibit-read-only t))
       (funcall handler code
                (decode-coding-string text locale-coding-system t))))))

(defun mistty--add-prompt-detection (accum)
  "Register processors to ACCUM for prompt detection.

Detected prompts can be found in `mistty-prompt'."
  (mistty--accum-add-post-processor
   accum #'mistty--term-postprocess-changed)
  (mistty--accum-add-post-processor
   accum (mistty--regexp-prompt-detector))

  ;; Enable bracketed paste
  (mistty--accum-add-processor
   accum
   '(seq CSI "?2004h")
   (lambda (ctx _)
     (mistty--accum-ctx-flush ctx)
     (unless mistty-bracketed-paste
       (let* ((prompt (mistty--prompt))
              (inhibit-read-only t)
              (inhibit-modification-hooks t)
              (scrolline (mistty--term-scrolline)))
         (when (or (null prompt)
                   (not (mistty--prompt-contains prompt scrolline)))
           ;; zsh enables bracketed paste only after having printed
           ;; the prompt. Try to find the beginning of the prompt
           ;; from prompt_sp or assume a single-line prompt.
           (when-let* ((real-start
                       (catch 'mistty-prompt-start
                         (dolist (i '(0 -1 -2 -3))
                           (let ((pos (pos-eol i)))
                             (when (and (zerop (mistty--prompt-counter))
                                        (= pos 1) (> (point) (pos-bol)))
                               (mistty-log "extend first prompt [1-%s]" (point))
                               (throw 'mistty-prompt-start (point-min)))
                             (when (get-text-property pos 'mistty-prompt-sp)
                               (mistty-log "prompt_sp %s [%s-%s]" i (1+ pos) (point))
                               (remove-text-properties
                                pos (1+ pos) '(term-line-wrap t 'mistty-prompt-sp nil))
                               (throw 'mistty-prompt-start (1+ pos)))))))
                      (eol (pos-eol)))
             (when (> eol real-start)
               ;; mistty--changed is only called when bracketed
               ;; paste is on; mark past sections of the prompt
               ;; as changed, including to the eol to cover
               ;; right prompts, also written before.
               (add-text-properties real-start eol '(mistty-updated t)))
             (setq scrolline (mistty--term-scrolline-at real-start)))
           (setq prompt (mistty--make-prompt 'bracketed-paste scrolline))
           (mistty--term-remove-prompt_sp prompt)
           (mistty-log "Detected %s prompt #%s [%s-]"
                       (mistty--prompt-source prompt)
                       (mistty--prompt-input-id prompt)
                       (mistty--prompt-start prompt))
           (setf (mistty--prompt) prompt))
         (unless (eq 'osc133 (mistty--prompt-source prompt))
           (setf (mistty--prompt-source prompt) 'bracketed-paste)
           (setf (mistty--prompt-end prompt) nil)))
       (setq mistty-bracketed-paste t))))

  ;; Disable bracketed paste
  (mistty--accum-add-processor
   accum
   '(seq CSI "?2004l")
   (lambda (ctx _)
     (mistty--accum-ctx-flush ctx)
     (when mistty-bracketed-paste
       (when-let* ((prompt (mistty--prompt))
                  (scrolline (if (eq ?\n (char-before (point)))
                                 (mistty--term-scrolline)
                               (1+ (mistty--term-scrolline)))))
         (when (and (eq 'bracketed-paste (mistty--prompt-source prompt))
                    (null (mistty--prompt-end prompt))
                    (> scrolline (mistty--prompt-start prompt)))
           (setf (mistty--prompt-end prompt) scrolline)))
       (setq mistty-bracketed-paste nil))))

  ;; Detect prompt-sp as many spaces followed by CR at the end of a
  ;; line.
  ;;
  ;; Not using " \r" as regexp for the processor as it would mean
  ;; waiting after a space in case a \r eventually comes. This isn't
  ;; an escape sequence.
  (mistty--accum-add-processor
   accum
   'CR
   (lambda (ctx _)
     ;; If we received at least 8 spaces before the \r (enough to fill
     ;; the look-back buffer) flush and look at the state of the
     ;; buffer just before the \r is taken into account.
     (when (string= "        " (mistty--accum-ctx-look-back ctx))
       (mistty--accum-ctx-flush ctx)
       (when (or (and (= (1- mistty-raw-width) (mistty-raw--cursor-column))
                      (eq ?\  (char-before (point))))
                 (and (get-text-property (pos-eol 0) 'term-line-wrap)
                      (string-match "^ *$" (buffer-substring (pos-bol) (pos-eol)))))
         (let ((inhibit-modification-hooks t)
               (inhibit-read-only t)
               (pos (pos-eol 0)))
           (put-text-property pos (1+ pos) 'mistty-prompt-sp t))))

     (mistty--accum-ctx-push-down ctx "\r"))))

(defun mistty--term-remove-prompt_sp (prompt)
  "Clear the mistty-prompt-sp property in PROMPT.

This should be called for all newly-detected prompt to avoid confusing
future prompts."
  (when-let* ((start (mistty--term-scrolline-pos
                     (mistty--prompt-start prompt))))
    (when (< start (point-max))
      (remove-text-properties (max (point-min) (1- start))
                              (point-max) '
                              (mistty-prompt-sp nil)))))

(defun mistty--regexp-prompt-detector ()
  "Build a post-processor that look for a new prompt at cursor.

The return value is meant to be
`mistty--accum-add-post-processor'.

 The post-processor updates `mistty--prompt' after the content of the
terminal buffer has been updated."
  (let ((last-nonempty-scrolline 0))
    (lambda ()
      (let ((scrolline (mistty--term-scrolline)))
        ;; Only look at new lines
        (when (> scrolline
                 (prog1 last-nonempty-scrolline
                   ;; for next time
                   (setq last-nonempty-scrolline
                         (mistty--term-scrolline-at
                          (mistty--last-non-ws)))))
          (let ((cursor (point))
                (bos (mistty--beginning-of-scrolline-pos))
                (prompt (mistty--prompt)))
            (when (and (or (null prompt)
                           (and (mistty--prompt-end prompt)
                                (>= scrolline (mistty--prompt-end prompt))))
                       (> cursor bos)
                       (>= cursor (mistty--last-non-ws))
                       (string-match
                        mistty--prompt-regexp
                        (mistty--safe-bufstring bos cursor)))
              (let ((prompt (mistty--make-prompt
                             'regexp scrolline (1+ scrolline)
                             :text (mistty--safe-bufstring bos (+ bos (match-end 0))))))
                (setf (mistty--prompt) prompt)
                (mistty-log "Suspected %s prompt #%s: [%s-%s] '%s'"
                            (mistty--prompt-source prompt)
                            (mistty--prompt-input-id prompt)
                            (mistty--prompt-start prompt)
                            (mistty--prompt-end prompt)
                            (mistty--prompt-text prompt))))))))))

(defun mistty-register-text-properties (id props)
  "Add PROPS to any text written to the terminal.

Call `mistty-unregister-text-properties' with the same ID to turn
that off.

If this function is called more than once with the same ID, only
the last set of properties to be registered is applied."
  (unless (eq 'term-mode major-mode) (error "Requires a term-mode buffer"))
  (if-let* ((cell (assq id mistty--term-properties-to-add-alist)))
      (setcdr cell props)
    (push (cons id props) mistty--term-properties-to-add-alist)))

(defun mistty-unregister-text-properties (id)
  "Stop applying properties previously registered with ID."
  (unless (eq 'term-mode major-mode) (error "Requires a term-mode buffer"))
  (when-let* ((cell (assq id mistty--term-properties-to-add-alist)))
    (setq mistty--term-properties-to-add-alist
          (delq cell
                mistty--term-properties-to-add-alist))))

(defun mistty--create-term (name program args local-map width height)
  "Create a new term buffer with name NAME.

The buffer runs PROGRAM with the given ARGS.

LOCAL-MAP specifies a local map to be used as the char-mode map.

WIDTH and HEIGHT are the initial dimension of the terminal
reported to the remote process.

This function returns the newly-created buffer."
  (let ((term-buffer (generate-new-buffer name 'inhibit-buffer-hooks)))
    (with-current-buffer term-buffer
      (mistty-raw-mode)
      (setq-local mistty--prompt-cell (mistty--make-prompt-cell))
      (setq-local scroll-margin 0)

      (mistty-raw-exec name program args width height)
      (let ((proc (get-buffer-process term-buffer)))
        (set-process-filter proc (mistty--make-accumulator
                                  #'mistty--emulate-terminal)))

      (when local-map
        (use-local-map local-map)))

    term-buffer))

(defun mistty--term-postprocess-changed ()
  "Process mistty-clear text properties.

This function turns mistty-clear into mistty-skip properties on the
lines that have changed since this processor was last rn."
  (when-let* ((change-start
               (text-property-any (point-min) (point-max) 'mistty-updated t)))
      (mistty--term-postprocess (point-min) mistty-raw-width)))

(defun mistty--term-postprocess (region-start window-width)
  "Set mistty-skip and yank handlers after REGION-START.

WINDOW-WIDTH is used to detect right prompts.

This sets properties from the mistty-clear properties,
detecting regions looking at a complete line."
  (save-excursion
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (goto-char region-start)
      (goto-char (pos-bol))
      (setq region-start (point))
      (remove-text-properties
       region-start (point-max)
       '(mistty-skip nil yank-handler nil mistty-updated nil))
      (let ((region-end (point-max)))
        (goto-char (point-max))
        (while (and (> (point) region-start)
                    (or (= (pos-bol) (pos-eol))
                        (not (text-property-not-all (pos-bol) (pos-eol) 'mistty-clear t))))
          (setq region-end (pos-eol 0))
          (forward-line -1))
        (when (< region-end (point-max))
          (put-text-property region-end (point-max) 'mistty-skip 'empty-lines-at-eob))
        (goto-char region-start)
        (while
            (progn
              (let ((bol (pos-bol))
                    (eol (pos-eol)))
                (when (> eol bol)
                  (unless (mistty--detect-right-prompt bol eol window-width)
                    (let ((end (or (mistty--detect-continue-prompt bol)
                                   (mistty--detect-indent bol eol))))
                      (mistty--detect-trailing-spaces end eol)))))

              ;; process next line?
              (forward-line 1)
              (< (point) region-end)))))))

(defun mistty--detect-right-prompt (bol eol window-width)
  "Detect right prompt and return its left position or nil.

BOL and EOL define the region to look in. WINDOW-WIDTH must be the width
of the terminal, usually `mistty-raw-width'."
  (let ((pos (1- eol)))
    (when (and (>= 3 (- window-width (mistty--line-width)))
               (not (get-text-property pos 'mistty-clear)))
      (when-let* ((first-maybe-skip (previous-single-property-change eol 'mistty-clear nil bol)))
        (when (and (eq (char-before first-maybe-skip) ?\ )
                   (> first-maybe-skip bol))
          (setq pos (1- first-maybe-skip))
          (while (and (>= pos bol)
                      (eq (char-after pos) ?\ )
                      (get-text-property pos 'mistty-clear))
            (cl-decf pos))
          (cl-incf pos)
          (add-text-properties
           pos eol '(mistty-skip right-prompt
                     yank-handler (nil "" nil nil)))

          pos)))))

(defun mistty--detect-continue-prompt (bol)
  "Detect continue prompt and return its right position or nil.

BOL define the start of the region to look in."
  (catch 'mistty-return
    (save-excursion
      (goto-char bol)
      (dolist (prompt mistty-multi-line-continue-prompts)
        (when (looking-at prompt)
          (let ((end (match-end 0)))
            (when (> end bol)
              (add-text-properties
               bol end
               '(mistty-skip continue-prompt yank-handler (nil "" nil nil)))
              (throw 'mistty-return end))))))))

(defun mistty--detect-indent (bol eol)
  "Detect line indentation and return its right position or nil.

BOL and EOL define the region to look in."
  (let ((pos bol))
    (while (and (eq (char-after pos) ?\ )
                (get-text-property pos 'mistty-clear))
      (cl-incf pos))
    (when (> pos bol)
      (when (= pos eol)
        (setq pos (min pos (+ bol (mistty--previous-line-indent)))))
      (put-text-property bol pos 'mistty-skip 'indent))

    pos))

(defun mistty--detect-trailing-spaces (bol eol)
  "Detect trailing spaces the left position or nil.

BOL and EOL define the region to look in."
  (let ((pos (1- eol)))
    (while (and (>= pos bol)
                (eq (char-after pos) ?\ )
                (get-text-property pos 'mistty-clear))
      (cl-decf pos))
    (cl-incf pos)

    (when (< pos eol)
      (add-text-properties
       pos eol
       `(mistty-skip trailing yank-handler (nil "" nil nil))))

    pos))

(defun mistty--previous-line-indent ()
  "Return the indentation of the previous line.

This requires the text property mistty-skip to have been set on
the previous line."
  (or
   (save-excursion
     (when (= 0 (forward-line -1))
       (let* ((bol (pos-bol))
              (eol (pos-eol))
              (pos bol))
         (while (and (< pos eol)
                     (eq 'indent (get-text-property pos 'mistty-skip)))
           (cl-incf pos))
         (- pos bol))))
   0))

(defun mistty--maybe-bracketed-str (str)
  "Prepare STR to be sent, possibly bracketed, to the terminal.

If bracketed paste is enabled and STR contains control and
bracketed paste is enabled, this function returns STR with
bracketed paste brackets around it."
  (let ((str (string-replace "\t" (make-string tab-width ? ) str)))
    (cond
     ((not mistty-bracketed-paste) str)
     ((not (string-match "[[:cntrl:]]" str)) str)
     (t (concat "\e[200~" str "\e[201~")))))

(defun mistty--hide-cursor ()
  "Temporarily hide the cursor.

Does nothing if the cursor is already hidden."
  (when cursor-type
    (if (local-variable-p 'cursor-type)
        (setq mistty--original-cursor cursor-type)
      (setq mistty--original-cursor nil))
    (setq cursor-type nil)))

(defun mistty--show-cursor ()
  "Show the cursor again, after `mistty--hide-cursor'.

Does nothing if the cursor is already shown."
  (when (and (local-variable-p 'cursor-type) (null cursor-type))
    (if mistty--original-cursor
        (setq cursor-type mistty--original-cursor
              mistty--original-cursor nil)
      (kill-local-variable 'cursor-type))))

(defun mistty--clear-term-face-value (value)
  "Clean a font-lock-face VALUE generated by term.el.

This just removes the default background and foreground, as set
on the term face."
  (pcase value
    (`((:foreground ,fg :background ,bg . ,more-props) . ,rest)
     (let ((props more-props))
       (unless (equal fg (face-foreground 'term nil 'default))
         (setq props (plist-put props :foreground fg)))
       (unless (equal bg (face-background 'term nil 'default))
         (setq props (plist-put props :background bg)))
       (append (list props) rest '(term))))
    (_ value)))

(defun mistty--detect-dead-spaces-after-insert (content beg)
  "Mark dead trailing spaces left by the terminal after inserting CONTENT.

When inserting a newline in an existing line, the terminal often just
overwrites the existing characters with space instead of re-creating the
line properly. The result are spaces that should be skipped.

BEG is the position at which CONTENT was inserted in the terminal
buffer.

Detected dead spaces are marked with the text property \\='mistty-skip
\\='dead."
  (let ((lines (split-string content "\n")))
    (when (length> lines 1)
      (let ((first-line (car lines)))
        (let ((real-trailing-ws 0))
          (while (string-suffix-p " " first-line)
            (cl-incf real-trailing-ws)
            (setq first-line (substring first-line 0 -1)))
          (save-excursion
            (goto-char beg)
            (let ((eol (pos-eol)))
              (goto-char eol)
              (skip-chars-backward " " (1- beg))
              (dotimes (_ real-trailing-ws)
                (when (eq ?\  (char-after (point)))
                  (goto-char (1+ (point)))))
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t))
                (when (> eol (point))
                  (mistty-log "@%s %s dead spaces, %s real"
                              eol (- eol (point)) real-trailing-ws)
                  (put-text-property (point) eol 'mistty-skip 'dead))))))))))

(defun mistty--term-reset-scrolline (scrolline)
  "Make the screen start at SCROLLINE.

This is useful after a reset, where scrolline have been lost. Generally,
this allows arbitrarily manipulating the alignment between the work and
terminal buffers. To avoid issues with prompt locations, it should only
be used to increase the value of `mistty-raw--home'."
  (setq mistty-raw--home-scrolline scrolline))

(defun mistty--term-scrolline ()
  "Return the current scrolline.

The scrolline count starts at the very beginning of the virtual buffer
and doesn't change as the buffer scrolls up or the terminal size
changes.

Before using a scrolline, convert it to a screen row or point."
  (mistty--term-scrolline-at (point)))

(defun mistty--term-scrolline-at (pos)
  "Return the scrolline at POS.

The scrolline count starts at the very beginning of the virtual buffer
and doesn't change as the buffer scrolls up or the terminal size
changes.

Before using a scrolline, convert it to a screen row or point."
  (+ mistty-raw--home-scrolline (mistty--count-scrollines mistty-raw--home pos)))

(defun mistty--term-scrolline-pos (scrolline)
  "Return the char position of the beginning of SCROLLINE.

Return nil if the row isn't reachable on the terminal."
  (save-excursion
    (goto-char mistty-raw--home)
    (when (zerop (mistty--go-down-scrollines (- scrolline mistty-raw--home-scrolline)))
      (point))))

(defun mistty--term-scrolline-at-screen-start()
  "Scrolline at the top of the screen."
  mistty-raw--home-scrolline)

(defun mistty-osc133 (_ osc-seq)
  "Handle OSC 133 codes.

OSC-SEQ contains the subcode followed optionally by a semi-colon and
arguments (ignored).

MisTTY supports code A-D:

 - A marks the start of a new command.
 - B marks the end of the prompt and the start of user input.
 - C marks the start of command output.
 - D marks the end of the command.

Everything else is ignored."
  (when (and (length> osc-seq 0) (not (mistty-raw--alt-screen-p)))
    (let ((command-char (aref osc-seq 0)))
      (pcase command-char
        (?A ;; start a new command

         ;; Overwrite any other prompt source.
         (let ((prompt (mistty--make-prompt 'osc133 (mistty--term-scrolline))))
           (setf (mistty--prompt) prompt)
           (mistty--term-remove-prompt_sp prompt)
           (mistty-log "Detected %s prompt #%s [%s-]"
                       (mistty--prompt-source prompt)
                       (mistty--prompt-input-id prompt)
                       (mistty--prompt-start prompt))))

        (?B ;; end of prompt/start of user input
         (when-let* ((prompt (mistty--prompt)))
           (setf (mistty--prompt-user-input-start prompt)
                 (cons (mistty--term-scrolline)
                       (mistty-raw--cursor-column)))))

        (?C ;; start of command output
         (when-let* ((prompt (mistty--prompt)))
           (when (eq 'osc133 (mistty--prompt-source prompt))
             (mistty-log "Closed %s prompt #%s [%s-]"
                         (mistty--prompt-source prompt)
                         (mistty--prompt-input-id prompt)
                         (mistty--prompt-start prompt))
             (setf (mistty--prompt-end prompt) (mistty--term-scrolline)))))

        (?D ;; end of command (possible anytime after ?A)
         (when-let* ((prompt (mistty--prompt)))
           (when (and (eq 'osc133 (mistty--prompt-source prompt))
                      (null (mistty--prompt-end prompt)))
             (mistty-log "Aborted %s prompt #%s [%s-]"
                         (mistty--prompt-source prompt)
                         (mistty--prompt-input-id prompt)
                         (mistty--prompt-start prompt))
             (setf (mistty--prompt-end prompt) (mistty--term-scrolline)))))))))

(defun mistty-call-term-mode-hook ()
  "Call the functions registered to `term-mode-hook'.

Remove this hook from `mistty-term-mode-hook' to allow the terminal
modes started by MisTTY to have a completely separate setup from normal
terminal modes. See the documentation of `mistty-term-mode-hook' for
details."
  (run-hooks 'mistty-shadowed-term-mode-hook))

(provide 'mistty-term)

;;; mistty-term.el ends here
