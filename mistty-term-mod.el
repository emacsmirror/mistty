;;; mistty-term-mod.el --- Use module to create the terminal -*- lexical-binding: t -*-

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
;; on top of mistty-raw.el

(require 'cl-lib)
(require 'mistty-term-base)
(require 'mistty-raw)
(require 'mistty-term)
(require 'mistty-accum)
(require 'mistty-scrolline)
(eval-when-compile
  (require 'mistty-accum-macros))

(cl-defstruct (mistty--term-mod
               (:constructor mistty--make-term-mod)
               (:copier nil))
  proc buf)

(cl-defmethod mistty--create-term ((_type (eql 'mod)) name command &key width height)
  (let ((term-buffer (generate-new-buffer name 'inhibit-buffer-hooks))
        (program (car command))
        (args (cdr command)))
    (with-current-buffer term-buffer
      (mistty-raw-mode)
      (setq-local mistty--prompt-cell (mistty--make-prompt-cell))
      (setq-local scroll-margin 0)
      (let ((process-environment
             (if (with-connection-local-variables mistty-set-EMACS)
                 (cons (format "EMACS=%s" emacs-version)
                       process-environment)
               process-environment)))
        (mistty-raw-exec name program args width height))
      (let* ((proc (get-buffer-process term-buffer))
             (term (mistty--make-term-mod :buf term-buffer :proc proc)))
        (set-process-filter proc (mistty--make-accumulator
                                  (mistty--term-filter-func term)))
        (process-put proc 'mistty-term term)

        term))))

(cl-defmethod mistty--term-buf ((term mistty--term-mod))
  (mistty--term-mod-buf term))

(cl-defmethod mistty--term-proc ((term mistty--term-mod))
  (mistty--term-mod-proc term))

(cl-defmethod mistty--term-screen-top-pos ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw--home))

(cl-defmethod mistty--term-screen-top-scrolline ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty--scrolline-home-num))

(cl-defmethod mistty--term-alt-screen-p ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw--alt-screen-p)))

(cl-defmethod mistty--term-lines ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw-lines))

(cl-defmethod mistty--term-columns ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    mistty-raw-columns))

(cl-defmethod mistty--term-cursor-linecol ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw--cursor-linecol)))

(cl-defmethod mistty--term-sentinel-func ((_term mistty--term-mod))
  #'mistty-raw--sentinel)

(cl-defmethod mistty--term-filter-func ((_term mistty--term-mod))
  #'mistty-raw--process-filter)

(cl-defmethod mistty--term-resize ((term mistty--term-mod) width height)
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw-resize width height))
  (set-process-window-size (mistty--term-mod-proc term) height width))

(cl-defmethod mistty--term-autoresize ((term mistty--term-mod) enable)
  (with-current-buffer (mistty--term-mod-buf term)
    (mistty-raw-auto-resize enable)))

(cl-defmethod mistty--term-setup-buffer ((_term mistty--term-mod) &optional _fullscreen))

(cl-defmethod mistty--term-setup-accum  ((term mistty--term-mod) accum
                                         &key enter-fullscreen active-prompt after-clear-screen)
  (mistty--add-prompt-detection accum term)
  (mistty--term-mod-add-osc-detection accum term)
  (unless enter-fullscreen (error ":enter-fullscreen required"))
  (mistty--accum-add-processor
   accum
   '(seq CSI (or "47" "?47" "?1047" "?1049") ?h)
   (lambda (ctx str)
     (mistty--accum-ctx-flush ctx)
     (funcall enter-fullscreen)
     (mistty--accum-ctx-push-down ctx str)))

  (unless active-prompt (error ":active-prompt required"))
  (mistty--accum-add-processor
   accum '(seq CSI ?2 ?J) ;; Clear screen
   (lambda (ctx str)
     (mistty--accum-ctx-flush ctx)
     (if (when-let* ((p (funcall active-prompt)))
           (equal
            (mistty--prompt-start p)
            (mistty--with-live-buffer (mistty--term-mod-buf term)
              mistty--scrolline-home-num)))
         (progn
           (mistty-log "CLEAR PROMPT (%S)" str)
           (mistty--accum-ctx-push-down
            ctx
            ;; This is equivalent to CSI 2J, but doesn't trigger
            ;; alacritty's storing the current screen content into
            ;; scrollback.
            "\e[1J\e[0J"))
       (mistty-log "CLEAR SCREEN (%S)" str)
       (mistty--accum-ctx-push-down ctx str)
       (mistty--accum-ctx-flush ctx)
       (when after-clear-screen
         (funcall after-clear-screen))))))

(cl-defmethod mistty--term-setup-accum-for-fullscreen ((term mistty--term-mod) accum
                                                       &key leave-fullscreen)
  (mistty--term-mod-add-osc-detection accum term)
  (unless leave-fullscreen (error ":leave-fullscreen required"))
  (mistty--accum-add-processor
   accum
   '(seq CSI (or "47" "?47" "?1047" "?1049") ?l)
   (lambda (ctx str)
     (mistty--accum-ctx-push-down ctx str)
     (mistty--accum-ctx-flush ctx)
     (funcall leave-fullscreen))))

(cl-defmethod mistty--term-clear-to-eol ((_term mistty--term-mod) pos)
  (mistty-raw--clear-to-eol pos))

(cl-defmethod mistty--term-cleanup-prompt-sp ((_term mistty--term-mod) pos)
  (mistty-raw--cleanup-prompt-sp pos))

(cl-defmethod mistty--term-postprocess-changed ((term mistty--term-mod))
  (with-current-buffer (mistty--term-mod-buf term)
    (when-let* ((change-start
                 (text-property-any (point-min) (point-max) 'mistty-updated t)))
      ;; TODO: use change-start instead of (point-min); this whole
      ;; business with mistty-updated is just silly otherwise.
      (mistty--term-postprocess (point-min) mistty-raw-columns)
      (remove-text-properties change-start (point-max) '(mistty-updated t)))))

(defun mistty--term-mod-add-osc-detection (accum term)
  "Register handlers for OSC sequences in ACCUM for TERM."

  ;; This intercepts just a few OSC sequences not supported by the
  ;; alacritty, let others through.
  (mistty--accum-add-processor-lambda
   accum
   (_ctx '(seq OSC "7;" (let text Pt) ST))
   (mistty-osc7 "7" text))
  (mistty--accum-add-processor-lambda
   accum
   (ctx '(seq OSC "133;" (let text Pt) ST))
   (mistty--accum-ctx-flush ctx) ;; for accurate cursor pos
   (unless (mistty--term-alt-screen-p term)
     (mistty-osc133 "133" text))))

(provide 'mistty-term-mod)

;;; mistty-term-mod.el ends here
