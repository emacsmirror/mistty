;;; mistty-accum.el --- Pre-processing process filter -*- lexical-binding: t -*-

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
;; This file defines an accumulator, which receives data coming from
;; the process, processes-it and eventually send it to the term
;; process filter.

(require 'seq)
(require 'subr-x)
(require 'pcase)
(require 'oclosure)
(require 'cl-lib)

(require 'mistty-util)
(require 'mistty-log)

;;; Code:

(defconst mistty--max-delay-processing-pending-output 0.1
  "Limits how long to spend processing pending output.

When MisTTY calls `accept-process-output', Emacs will read data from the
process as long as there is some. If the process keeps sending data, the
whole Emacs process would freeze for that long. This limit must be kept
low or Emacs might become unresponsive when the process outputs data
continuously.")

(oclosure-define (mistty--accumulator
                  (:predicate mistty--accumulator-p))
  "Process Output Accumulator.

Use this function as process filter to accumulate and process data
before sending it to its destination filter.

Processors can be added to the accumulator to react to specific terminal
sequences being found in the flow before it gets to the real process
filter. See `mistty--accumulator-add-processor'

Post-processors can be added to the accumulator to react to changes made
by the real process filter. See
`mistty--accumulator-add-post-processor'.

Usage example:
  (let ((accum (mistty--make-accumulator #'real-process-filter)))
    (process-set-filter proc accum)
    (mistty--accumulator-add-processor accum ...)
    ...
"
  ;; The following slots are meant to be accessed only by
  ;; mistty-make-accumulator and its helper functions.

  ;; The real process filter; a function with arguments (proc data)
  (destination :mutable t)
  ;; Alist of (cons regexp (lambda (ctx str)))
  (processor-alist :mutable t)
  ;; Set to non-nil after changing processor-alist.
  (processor-alist-dirty :mutable t)
  ;; Set of no-arg functions to call after calling process-filter.
  (post-processors :mutable t))

(defsubst mistty--accumulator-clear-processors (accum)
  "Remove all (post-)processors registered for ACCUM."
  (setf (mistty--accumulator--processor-alist accum) nil)
  (setf (mistty--accumulator--processor-alist-dirty accum) t)
  (setf (mistty--accumulator--post-processors accum) nil))

(defsubst mistty--accumulator-add-post-processor (accum post-processor)
  "Add POST-PROCESSOR to ACCUM.

POST-PROCESSOR must be a function that takes no argument. It is called
after the real process filter, once there are no remaining pending
processed data to send."
  (push post-processor (mistty--accumulator--post-processors accum)))

(defsubst mistty--accumulator-add-processor (accum regexp processor)
  "Register PROCESSOR in ACCUM for processing REGEXP.

PROCESSOR must be a function with signature (CTX STR). With CTX a
`mistty--accumulator-ctx' instance and STR the terminal sequence that
matched the regexp. The processor is executed with the process buffer as
current buffer.

If PROCESSOR does nothing, the terminal sequence matching REGEXP is
simply swallowed. To forward or modify it, PROCESSOR must call
`mistty--accumulator-ctx-push-down'.

If PROCESSOR needs to check the state of the process buffer, it must
first make sure that that state has been fully updated to take into
account everything that was sent before the matching terminal sequence
by calling `mistty--accumulator-ctx-flush'."
  (push (cons regexp processor) (mistty--accumulator--processor-alist accum))
  (setf (mistty--accumulator--processor-alist-dirty accum) t))

(cl-defstruct (mistty--accumulator-ctx
               (:constructor mistty--make-accumulator-ctx)
               (:conc-name mistty--accumulator-ctx-))
  "Allow processors to communicate with the accumulator"
  ;; Flush accumulator (no-arg function).
  ;; Call it through mistty--accumulator-ctx-flush.
  flush-f
  ;; Send processed string to destination (single-arg function)
  ;; Call it through mistty--accumulator-ctx-push-down.
  push-down-f)

(defsubst mistty--accumulator-ctx-flush (ctx)
  "Flush accumulator from a processor.

Flushing from a processor sends all data processed so far to the
destination process filter. There's likely to be more data left
afterwards.

Post-processors are not run after every flush, but rather when all data
has been processed.

CTX is the context passed to the current processor.

If the process buffer is killed while handling the flush, the processor
is interrupted."
  (funcall (mistty--accumulator-ctx-flush-f ctx)))

(defsubst mistty--accumulator-ctx-push-down (ctx str)
  "Send STR to destination from a processor.

CTX is the context passed to the current processor."
  (funcall (mistty--accumulator-ctx-push-down-f ctx) str))


(defun mistty--make-accumulator (dest)
  "Make an accumulator that sends process output to DEST.

An accumulator is a function with the signature (PROC DATA) that is
meant to be used as process filter. It intercepts, buffers and
transforms process data before sending it to DEST.

DEST is the destination process filter function, with the same
signature (PROC DATA).

The return value of this type is also an oclosure of type
mistty--accumulator whose slots can be accessed."
  (let ((unprocessed (mistty--make-fifo))
        (processed (mistty--make-fifo))
        (overall-processor-regexp nil)
        (processing-pending-output nil)
        (processor-vector [])
        (needs-postprocessing nil))
    (cl-labels
        ;; Collect all pending strings from FIFO into one
        ;; single string.
        ;;
        ;; The fifo is cleared.
        ;;
        ;; Return a single, possibly empty, string.
        ((fifo-to-string (fifo)
           (let ((lst (mistty--fifo-to-list fifo)))
             (pcase (length lst)
               (0 "")
               (1 (car lst))
               (_ (mapconcat #'identity lst)))))

         ;; Send all processed data to DEST.
         (flush (dest proc)
           (let ((data (fifo-to-string processed)))
             (unless (string-empty-p data)
               (funcall dest proc data)
               (setq needs-postprocessing t))))

         ;; Call post-processors after everything has been processed.
         (post-process (proc post-processors)
           (when needs-postprocessing
             (setq needs-postprocessing nil)
             (dolist (p (reverse post-processors))
               (mistty--with-live-buffer (process-buffer proc)
                 (funcall p)))))

         ;; Check whether the current instance should flush the data.
         ;;
         ;; The accumulator calls accept-process-output, which, since
         ;; the accumulator is the process filter, makes Emacs calls
         ;; accumulator recursively.
         ;;
         ;; Recursive calls should not flush, only the toplevel call
         ;; should.
         (toplevel-accumulator-p (proc)
           (if processing-pending-output
               (prog1 nil ; don't flush
                 (when (>= (time-to-seconds (time-subtract
                                             (current-time)
                                             processing-pending-output))
                           mistty--max-delay-processing-pending-output)
                   (throw 'mistty-stop-accumlating nil)))
             (prog1 t ; flush
               (unwind-protect
                   (progn
                     ;; accept-process-output calls the accumulator
                     ;; recursively as there's pending data.
                     (setq processing-pending-output (current-time))
                     (catch 'mistty-stop-accumlating
                       (accept-process-output proc 0 nil 'just-this-one)))
                 (setq processing-pending-output nil)))))

         ;; Build a new value for overall-processor-regexp.
         ;;
         ;; This is a big concatenation of all regexps in
         ;; PROCESSOR-ALIST or nil if the alist is empty.
         ;;
         ;; WARNING: regexps must not define groups. TODO: enforce
         ;; this.
         (build-overall-processor-regexp (processor-alist)
           (when processor-alist
             (let ((index 0))
               (mapconcat
                (pcase-lambda (`(,regexp . ,_))
                  (cl-incf index)
                  (format "\\(?%d:%s\\)" index regexp))
                processor-alist
                "\\|"))))

         ;; Build a new value for processor-vector.
         ;;
         ;; The vector contain the processor function whose indexes
         ;; correspond to groups in overall-processor-regexp.
         (build-processor-vector (processor-alist)
           (vconcat (mapcar #'cdr processor-alist)))

         ;; Add STR as processed string
         (push-down (str)
           (mistty--fifo-enqueue processed str))

         ;; Process any data in unprocessed and move it to processed.
         (process-data (dest proc)
           (let ((data (fifo-to-string unprocessed)))
             (while (not (string-empty-p data))
               (if (and overall-processor-regexp
                        (string-match overall-processor-regexp data))
                   (let* ((before (substring data 0 (match-beginning 0)))
                          (matching (substring
                                     data (match-beginning 0) (match-end 0)))
                          (processor (cl-loop for i from 1
                                              for p across processor-vector
                                              thereis (when (match-beginning i)
                                                        p))))
                     (setq data (substring data (match-end 0))) ; next loop

                     (unless (string-empty-p before)
                       (mistty--fifo-enqueue processed before))
                     (mistty--with-live-buffer (process-buffer proc)
                       (catch 'mistty-abort-processor
                         (funcall
                          processor
                          (mistty--make-accumulator-ctx
                           :flush-f (lambda ()
                                      (flush dest proc)
                                      (unless (buffer-live-p (process-buffer proc))
                                        (throw 'mistty-abort-processor nil)))
                           :push-down-f #'push-down)
                          matching))))
                 (mistty--fifo-enqueue processed data)
                 (setq data ""))))))

      ;; Build the accumulator as an open closure.
      (oclosure-lambda (mistty--accumulator (destination dest)
                                            (processor-alist-dirty t))
          (proc data)
        (mistty--fifo-enqueue unprocessed data)
        (when (toplevel-accumulator-p proc)
          (when processor-alist-dirty
            (setq overall-processor-regexp (build-overall-processor-regexp processor-alist))
            (setq processor-vector (build-processor-vector processor-alist))
            (setq processor-alist-dirty nil))
          (process-data destination proc)
          (flush destination proc)
          (post-process proc post-processors))))))

(provide 'mistty-accum)

;;; mistty-accum.el ends here
