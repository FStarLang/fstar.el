;;; fstar-mode.el --- support for the F* language in Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2015 Clément Pit--Claudel
;; Author: Clément Pit--Claudel <clement.pitclaudel@live.com>
;; URL: https://github.com/FStarLang/fstar.el

;; Created: 27 Aug 2015
;; Version: 0.1
;; Package-Requires: ((flycheck "0.25") (emacs "24.3") (dash "2.11"))
;; Keywords: convenience, languages

;; This file is not part of GNU Emacs.

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;; http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;;; Commentary:

;; This file implements basic support for programming in F* in Emacs.

;;; Code:

;;; Imports

(require 'dash)
(require 'cl-lib)
(require 'flycheck)

;;; Compatibility

(defmacro fstar-assert (&rest args)
  "Call `assert' on ARGS, if available."
  (declare (debug t))
  `(when (fboundp 'assert)
     (assert ,@args)))

;;; Group

(defgroup fstar nil
  "F* mode."
  :group 'languages)

;;; Flycheck

(flycheck-def-executable-var fstar "fstar.exe")

(defconst fstar-error-patterns
  (let ((fstar-pat '((message) "near line " line ", character " column " in file " (file-name)))
        (z3-pat  '((file-name) "(" line "," column "-" (+ (any digit)) "," (+ (any digit)) ")"
                   (* (any ": ")) (? "Error" (* (any " \n")))
                   (message))))
    `((error "ERROR: " ,@fstar-pat)
      (warning "WARNING: " ,@fstar-pat)
      (error ,@z3-pat))))

(flycheck-define-command-checker 'fstar
  "Flycheck checker for F*."
  :command '("fstar.exe" source-inplace)
  :error-patterns fstar-error-patterns
  :error-filter #'flycheck-increment-error-columns
  :modes '(fstar-mode))

(add-to-list 'flycheck-checkers 'fstar)

;;; Build config

(defconst fstar-build-config-header "(*--build-config")
(defconst fstar-build-config-footer "--*)")

;; (defun fstar-read-build-config ()
;;   (save-excursion
;;     (save-restriction
;;       (widen)
;;       (goto-char (point-min))
;;       (-when-let* ((beg (search-forward fstar-build-config-header nil t))
;;                    (end (search-forward fstar-build-config-footer nil t)))))))

(defun fstar-setup-flycheck ()
  (flycheck-mode))

;;; Prettify symbols

(defconst fstar-symbols-alist '(("exists" . ?∃) ("forall" . ?∀) ("fun" . ?λ)
                                ("nat" . ?ℕ) ("int" . ?ℤ)
                                ("True" . ?⊤) ("False" . ?⊥)
                                ("*" . ?×) ("~>" . ?↝)
                                ("<=" . ?≤) (">=" . ?≥) ("::" . ?⸬)
                                ("/\\" . ?∧) ("\\/" . ?∨) ("=!=" . ?≠)
                                ("&&" . ?∧) ("||" . ?∨) ("<>" . ?≠)
                                ("<==>" . ?⟺) ("==>" . ?⟹)
                                ("=>" . ?⇒) ("->" . ?→)
                                ;; ("(|" . 10629) ("|)" . 10630)
                                ("'a" . ?α) ("'b" . ?β) ("'c" . ?γ)
                                ("'d" . ?δ) ("'e" . ?η))
  "Fstar symbols.")


(defun fstar-setup-prettify ()
  "Setup prettify-symbols for use with F*."
  (when (and (boundp 'prettify-symbols-alist)
             (fboundp 'prettify-symbols-mode))
    (setq-local prettify-symbols-alist (append fstar-symbols-alist
                                               prettify-symbols-alist))
    (prettify-symbols-mode)))

;;; Font-Lock

;; Loosely derived from https://github.com/FStarLang/atom-fstar/blob/master/grammars/fstar.cson

(defconst fstar-syntax-structure
  (regexp-opt '("begin" "end"
                "let" "rec" "in" "val"
                "kind" "type" "logic"
                "private" "opaque" "total" "default"
                "open" "module")
              'symbols))

(defconst fstar-syntax-preprocessor
  (regexp-opt '("#set-options")
              'symbols))

(defconst fstar-syntax-keywords
  (regexp-opt '("and"
                "forall" "exists"
                "assert" "assume"
                "fun" "function"
                "match" "with"
                "if" "then" "else"
                "ALL" "All" "DIV" "Div" "EXN" "Ex" "Exn" "GHOST" "GTot" "Ghost"
                "Lemma" "PURE" "Pure" "ST" "STATE" "St" "Tot")
              'symbols))

(defconst fstar-syntax-builtins
  (regexp-opt '("requires" "ensures" "modifies" "decreases"
                "effect" "new_effect" "sub_effect")
              'symbols))

;; (defconst fstar-syntax-types
;;   (regexp-opt '("Type")
;;               'symbols))

(defconst fstar-syntax-constants
  (regexp-opt '("False" "True")
              'symbols))

(defface fstar-structure-face
  '((((background light)) (:bold t))
    (t :bold t :foreground "salmon"))
  "Face used to highlight structural keywords."
  :group 'fstar)

(defface fstar-subtype-face
  '((t :italic t))
  "Face used to highlight subtyping clauses."
  :group 'fstar)

(defface fstar-attribute-face
  '((t :italic t))
  "Face used to highlight attributes."
  :group 'fstar)

(defface fstar-decreases-face
  '((t :italic t))
  "Face used to highlight decreases clauses."
  :group 'fstar)

(defun fstar-group-pre-matcher (prefix-len allowed-newlines)
  "Prepare for highlighting.

Go back PREFIX-LEN chars, skip one sexp forward without moving
point and report that position; point is placed at beginning of
original match.  If ALLOWED-NEWLINES is non-nil, then allow the
sexp to span at most that many extra lines."
  (prog1
      (min (save-excursion
             (backward-char prefix-len)
             (ignore-errors (forward-sexp))
             (point))
           (save-excursion
             (forward-line (or allowed-newlines 0))
             (point-at-eol)))
    (goto-char (match-beginning 0))))

(defun fstar-subexpr-pre-matcher (rewind-to &optional bound-to)
  (goto-char (match-end rewind-to))
  (match-end (or bound-to 0)))

(defconst fstar-syntax-id (rx symbol-start
                              (? (or "#" "'"))
                              (any "a-z_") (* (or wordchar (syntax symbol)))
                              (? "." (* (or wordchar (syntax symbol))))
                              symbol-end))

(defconst fstar-syntax-cs (rx symbol-start
                              (any "A-Z") (* (or wordchar (syntax symbol)))
                              symbol-end))

(defun fstar-find-id-with-type (bound)
  (fstar-find-id-maybe-type bound t))

(defun fstar-find-id-maybe-type (bound must-find-type)
  (let ((found t) (rejected t))
    (while (and found rejected)
      (setq found (re-search-forward (concat "\\(" fstar-syntax-id "\\) *\\(:\\)?") bound t))
      (setq rejected (and found (or (eq (char-after) ?:) ; h :: t
                                    (and must-find-type (not (match-beginning 2))) ; no type
                                    (save-excursion
                                      (goto-char (match-beginning 0))
                                      (skip-syntax-backward "-")
                                      (or (eq (char-before) ?|) ; | X: int
                                          (save-match-data
                                            (looking-back "\\_<val" (point-at-bol))))))))) ; val x : Y:int
    (when (and found (match-beginning 2))
      (ignore-errors
        (goto-char (match-end 2))
        (forward-sexp)
        (let ((md (match-data)))
          (set-match-data `(,(car md) ,(point) ,@(cddr md))))))
    found))

(defun fstar-find-id (bound)
  (fstar-find-id-maybe-type bound nil))

(defun fstar-find-fun-and-args (bound)
  (let ((found))
    (while (and (not found) (re-search-forward "\\_<fun\\_>" bound t))
      (-when-let* ((mdata (match-data))
                   (fnd   (search-forward "->" bound t))) ;;FIXME
        (set-match-data `(,(car mdata) ,(match-end 0)
                          ,@mdata))
        (setq found t)))
    found))

(defun fstar-find-subtype-annotation (bound)
  (let ((found))
    (while (and (not found) (re-search-forward "{[^:]" bound t))
      (setq found
            (save-excursion
              (backward-char)
              (not (looking-at-p "[^ ]+ +with")))))
    found))

(defconst fstar-syntax-additional
  (let ((id fstar-syntax-id))
    `(
      (fstar-find-subtype-annotation
       ("{\\(\\(?:.\\|\n\\)+\\)}"
        (fstar-group-pre-matcher 2 5) nil
        (1 'fstar-subtype-face append)))
      ("{:" (,(concat "\\({\\)\\(:" id "\\)\\(\\(?: +.+\\)?\\)\\(}\\)")
             (fstar-group-pre-matcher 2 2) nil
             (2 'font-lock-function-name-face append)
             (3 'fstar-attribute-face append)))
      ("%\\[" ("%\\[\\([^]]+\\)\\]"
               (fstar-group-pre-matcher 1 0) nil
               (1 'fstar-decreases-face append)))
      (,(concat "\\_<\\(let\\(?: +rec\\)?\\)\\(\\(?: +" id "\\)?\\) +[^=]+=")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 2) nil
                      (1 'font-lock-variable-name-face)))
      (fstar-find-id-with-type
       (1 'font-lock-variable-name-face))
      (,(concat "\\_<\\(type\\|kind\\)\\( +" id "\\)\\s-*$")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(concat "\\_<\\(type\\|kind\\)\\( +" id "\\)[^=]+=")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 2) nil
                      (1 'font-lock-variable-name-face)))
      ("\\_<\\(forall\\|exists\\) [^.]+\."
       (0 'font-lock-keyword-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 1) nil
                      (1 'font-lock-variable-name-face)))
      (fstar-find-fun-and-args
       (1 'font-lock-keyword-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 1) nil
                      (1 'font-lock-variable-name-face)))
      (,(concat "\\_<\\(val\\) +\\(" id "\\) *:")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,fstar-syntax-cs (0 'font-lock-constant-face))
      ("(\\*--\\(build-config\\)"
       (1 'font-lock-preprocessor-face prepend)))))

(defun fstar-setup-font-lock ()
  "Setup font-lock for use with F*."
  (setq-local
   font-lock-defaults
   `(((,fstar-syntax-constants    . 'font-lock-constant-face)
      (,fstar-syntax-keywords     . 'font-lock-keyword-face)
      (,fstar-syntax-builtins     . 'font-lock-builtin-face)
      (,fstar-syntax-preprocessor . 'font-lock-preprocessor-face)
      (,fstar-syntax-structure    . 'fstar-structure-face)
      ,@fstar-syntax-additional)
     nil nil))
  (font-lock-set-defaults))

;;; Syntax table

(defvar fstar-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "_" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?' "_" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?*  ". 23" table)
    (modify-syntax-entry ?/  ". 12b" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\( "()1n" table)
    (modify-syntax-entry ?\) ")(4n" table)
    table)
  "Syntax table for F*.")

;;; Mode map

(defvar fstar-mode-map
  (make-sparse-keymap))

;;; Indentation

(defun fstar-indentation-points ()
  "Find reasonable indentation points on the current line."
  (let ((points)) ;; FIXME first line?
    (save-excursion
      (forward-line -1)
      (while (re-search-forward "\\s-+" (point-at-eol) t)
        (push (current-column) points)))
    (when points
      (push (+ 2 (apply #'min points)) points))
    (push 0 points)
    (push 2 points)
    (-distinct (sort points #'<))))

(defun fstar-indent ()
  "Cycle between vaguely relevant indentation points."
  (interactive)
  (let* ((current-ind (current-indentation))
         (points      (fstar-indentation-points))
         (remaining   (-filter (lambda (x) (> x current-ind)) points))
         (target      (car (or remaining points))))
    (if (> (current-column) current-ind)
        (save-excursion (indent-line-to target))
      (indent-line-to target))))

(defun fstar-setup-indentation ()
  "Setup indentation for F*."
  (setq-local indent-line-function #'fstar-indent)
  (when (fboundp 'electric-indent-local-mode)
    (electric-indent-local-mode -1)))

;;; Interaction with the server (interactive mode)

(defconst fstar-subp--success "ok")
(defconst fstar-subp--failure "nok")
(defconst fstar-subp--done "\n#done-")

(defconst fstar-subp--cancel "#pop\n")
(defconst fstar-subp--header "#push\n")
(defconst fstar-subp--footer "\n#end #done-ok #done-nok\n")

(defconst fstar-subp-statuses '(pending busy processed))

(defvar-local fstar-subp--process nil
  "Interactive F* process running in the background.")

(defvar-local fstar-subp--busy-now nil
  "Indicates which overlay the F* subprocess is currently processing, if any.")

(defface fstar-subp-overlay-pending-face
  '((t :background "grey"))
  "Face used to highlight pending sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-busy-face
  '((((background light)) :background "mistyrose")
    (((background dark))  :background "mediumorchid"))
  "Face used to highlight busy sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-processed-face
  '((((background light)) :background "#eaf8ff")
    (((background dark))  :background "darkslateblue"))
  "Face used to highlight processed sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-issue-face
  '((t :underline (:color "red" :style wave)))
  "Face used to highlight processed sections of the buffer."
  :group 'fstar)

(defmacro fstar-subp-log (format &rest args)
  "Log a query or response.

FORMAT and ARGS are as in `message'."
  (declare (debug t))
  `(message ,format ,@args))

(defun fstar-subp-live-p (&optional proc)
  "Return t if the PROC is a live F* subprocess.

If PROC is nil, use the current buffer's `fstar-subp--process'."
  (setq proc (or proc fstar-subp--process))
  (and proc (process-live-p proc)))

(defun fstar-subp-killed (proc)
  "Clean up buffer after PROC was killed."
  (-when-let* ((procp proc)
               (buf   (process-buffer proc))
               (bufp  (buffer-live-p buf)))
    (kill-buffer buf))
  (fstar-subp-remove-tracking-overlays)
  (fstar-subp-remove-issues-overlays)
  (setq fstar-subp--busy-now nil
        fstar-subp--process nil))

(defun fstar-subp-kill ()
  "Kill F* subprocess and clean up buffer."
  (interactive)
  (when (fstar-subp-live-p)
    (kill-process fstar-subp--process)
    (accept-process-output fstar-subp--process))
  (fstar-subp-killed fstar-subp--process))

(defun fstar-subp-sentinel (proc _signal)
  "Hamdle signals from PROC."
  (when (not (process-live-p proc))
    (fstar-subp-killed proc)))

(defun fstar-subp-remove-tracking-overlays ()
  "Remove all F* overlays in the current buffer."
  (mapcar #'delete-overlay (fstar-subp-tracking-overlays)))

(defun fstar-subp-remove-issues-overlays ()
  "Remove all F* overlays in the current buffer."
  (mapcar #'delete-overlay (fstar-subp-issues-overlays)))

(defmacro fstar-subp-with-process-buffer (proc &rest body)
  "Move to PROC's buffer to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((livep    (fstar-subp-live-p ,proc))
                (buf      (process-buffer ,proc))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

(defmacro fstar-subp-with-source-buffer (proc &rest body)
  "Move to parent buffer of PROC to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((livep    (fstar-subp-live-p ,proc))
                (buf      (process-get ,proc 'fstar-subp-source-buffer))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

(defun fstar-subp-find-response (proc)
  "Find full response in PROC's buffer; handle it if found."
  (goto-char (point-min))
  (when (search-forward fstar-subp--done nil t)
    (let* ((status        (cond
                           ((looking-at fstar-subp--success) t)
                           ((looking-at fstar-subp--failure) nil)))
           (resp-beg      (point-min))
           (resp-end      (point-at-bol))
           (resp-real-end (point-at-eol))
           (response      (string-trim (buffer-substring resp-beg resp-end))))
      ;; string-trim is defined by flycheck if not present
      (fstar-subp-log "RESPONSE [%s] [%s]" status response)
      (delete-region resp-beg resp-real-end)
      (fstar-subp-with-source-buffer proc
        (fstar-subp-process-response status response)))))

(defun fstar-subp-clear-issues ()
  "Remove all issue overlays from current buffer."
  (cl-loop for ov being the overlays of (current-buffer)
           when (overlay-get ov 'fstar-subp-issue)
           do (delete-overlay ov)))

(defun fstar-subp-process-response (status response)
  "Process output STATUS and RESPONSE from F* subprocess."
  (let* ((overlay fstar-subp--busy-now))
    (unless overlay
      (fstar-subp-kill)
      (error "Invalid state: Received output, but no region was busy"))
    (setq fstar-subp--busy-now nil)
    (fstar-subp-clear-issues)
    (pcase status
      (`t   (fstar-subp-handle-success response overlay))
      (`nil (fstar-subp-handle-failure response overlay))
      (_    (fstar-subp-kill)
            (error "Unknown status [%s] from F* subprocess (response was [%s])"
                   status response)))))

(defun fstar-subp-handle-success (response overlay)
  "Process success RESPONSE from F* subprocess for OVERLAY."
  (when (not (string= response ""))
    (warn "Non-empty response despite prover success: [%s]" response))
  (fstar-subp-set-status overlay 'processed)
  (run-with-timer 0 nil #'fstar-subp-process-queue))

(cl-defstruct fstar-issue
  level filename line-from line-to col-from col-to message)

(defconst fstar-subp-issue-regexp
  "\\(.*?\\)(\\([[:digit:]]+\\),\\([[:digit:]]+\\)-\\([[:digit:]]+\\),\\([[:digit:]]+\\)):\\s-*\\(.*\\)")

(defun fstar-subp-parse-issue (context)
  "Construct an issue object from the current match data and CONTEXT."
  (pcase-let ((`(,filename ,line-from ,col-from ,line-to ,col-to ,message)
               (mapcar (lambda (num) (match-string-no-properties num context))
                       '(1 2 3 4 5 6))))
    (make-fstar-issue :level "ERROR"
                      :filename filename
                      :line-from (string-to-number line-from)
                      :col-from (string-to-number col-from)
                      :line-to (string-to-number line-to)
                      :col-to (string-to-number col-to)
                      :message message)))

(defun fstar-subp-parse-issues (response)
  "Parse RESPONSE into a list of issues."
  (let ((start 0))
    (cl-loop while (string-match fstar-subp-issue-regexp response start)
             collect (fstar-subp-parse-issue response)
             do (setq start (match-end 0)))))

(defun fstar-subp-adjust-line-numbers (issue overlay-start-line)
  "Adjust line numbers of ISSUE relative to OVERLAY-START-LINE."
  (setf (fstar-issue-line-from issue) (+ (fstar-issue-line-from issue) (1- overlay-start-line)))
  (setf (fstar-issue-line-to issue) (+ (fstar-issue-line-to issue) (1- overlay-start-line))))

(defun fstar-subp-realign-issue (overlay-start-line issue)
  "Use first line of overlay (OVERLAY-START-LINE) to realign issue ISSUE."
  (when (string= (fstar-issue-filename issue) "<input>")
    (setf (fstar-issue-filename issue) (buffer-file-name)) ;; FIXME ensure we have a file name?
    (fstar-subp-adjust-line-numbers issue overlay-start-line))
  issue)

(defun fstar-subp-realign-issues (overlay issues)
  "Use beginning of OVERLAY to realign issues ISSUES."
  (let ((start-line (line-number-at-pos (overlay-start overlay))))
    (mapcar (apply-partially #'fstar-subp-realign-issue start-line) issues)))

(defun fstar-issue-offset (line column)
  "Convert a (LINE, COLUMN) pair into a buffer offset.

FIXME: This would be much easier if the interactive mode returned
an offset instead of a line an column.
FIXME: This doesn't do error handling."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (forward-char column)
    (point)))

(defun fstar-subp-remove-issue-overlay (overlay &rest _args)
  "Remove OVERLAY."
  (delete-overlay overlay))

(defun fstar-subp-highlight-issue (issue)
  "Highlight ISSUE in current buffer."
  (let* ((from (fstar-issue-offset (fstar-issue-line-from issue)
                                   (fstar-issue-col-from issue)))
         (to (fstar-issue-offset (fstar-issue-line-to issue)
                                 (fstar-issue-col-to issue)))
         (overlay (make-overlay from to (current-buffer) t nil)))
    (overlay-put overlay 'fstar-subp-issue t)
    (overlay-put overlay 'face 'fstar-subp-overlay-issue-face)
    (overlay-put overlay 'help-echo (fstar-issue-message issue))
    (overlay-put overlay 'modification-hooks '(fstar-subp-remove-issue-overlay))
    (when (fboundp 'pulse-momentary-highlight-region)
      (pulse-momentary-highlight-region from to))))

(defun fstar-subp-highlight-issues (issues)
  "Highlight ISSUES whose name match that of the current buffer."
  (fstar-assert issues)
  (mapcar #'fstar-subp-highlight-issue issues))

(defun fstar-subp-jump-to-issue (issue)
  "Jump to ISSUE in current buffer."
  (goto-char (fstar-issue-offset (fstar-issue-line-from issue)
                                 (fstar-issue-col-from issue))))

(defun fstar-subp-handle-failure (response overlay)
  "Process failure RESPONSE from F* subprocess for OVERLAY."
  (let* ((issues   (fstar-subp-parse-issues response))
         (aligned  (fstar-subp-realign-issues overlay issues))
         (filtered (-filter (lambda (issue) (string= buffer-file-name (fstar-issue-filename issue))) aligned)))
    (fstar-subp-remove-unprocessed)
    (process-send-string fstar-subp--process fstar-subp--cancel)
    (cond ((null issues)
           (warn "No issues found in response despite prover failure: [%s]" response))
          ((null filtered)
           (warn "F* checker reported issues in other files: [%s] (FIXME)" response))
          (t
           (fstar-subp-log "Highlighting issues: %s" issues)
           (fstar-subp-jump-to-issue (car filtered))
           (fstar-subp-highlight-issues aligned)
           (display-local-help)))))

(defun fstar-subp-status-eq (overlay status)
  "Check if OVERLAY has status STATUS."
  (eq (overlay-get overlay 'fstar-subp-status) status))

(defun fstar-subp-remove-unprocessed ()
  "Remove pending and busy overlays."
  (cl-loop for overlay in (fstar-subp-tracking-overlays)
           unless (fstar-subp-status-eq overlay 'processed)
           do (delete-overlay overlay)))

(defun fstar-subp-filter (proc string)
  "Handle PROC's output (STRING)."
  (when string
    (fstar-subp-log "OUTPUT [%s]" (replace-regexp-in-string "\n" " // " string t t))
    (fstar-subp-with-process-buffer proc
      (goto-char (point-max))
      (insert string)
      (fstar-subp-find-response proc))))

(defun fstar-subp-make-buffer ()
  "Create a buffer for the F* subprocess."
  (with-current-buffer (generate-new-buffer
                        (format " *F* interactive for %s" (buffer-name)))
    (buffer-disable-undo)
    (current-buffer)))

(defun fstar-subp-start ()
  "Start an F* subprocess attached to the current buffer, if none exists."
  (unless fstar-subp--process
    (let* ((buf (fstar-subp-make-buffer))
           (proc (start-process "F* interactive" buf
                                flycheck-fstar-executable "--in")))
      (set-process-filter proc #'fstar-subp-filter)
      (set-process-sentinel proc #'fstar-subp-sentinel)
      (process-put proc 'fstar-subp-source-buffer (current-buffer))
      (setq fstar-subp--process proc))))

(defun fstar-subp-send-region (beg end)
  "Send the region between BEG and END to the inferior F* process."
  (interactive "r")
  (fstar-subp-start)
  (let ((msg (concat fstar-subp--header
                     (buffer-substring-no-properties beg end)
                     fstar-subp--footer)))
    (fstar-subp-log "QUERY [%s]" msg)
    (process-send-string fstar-subp--process msg)))

(defun fstar-subp-tracking-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp tracking overlay."
  (overlay-get overlay 'fstar-subp-status))

(defun fstar-subp-tracking-overlays (&optional status)
  "Find all -subp tracking overlays with status STATUS in the current buffer.

If STATUS is nil, return all fstar-subp overlays."
  (sort (cl-loop for overlay being the overlays of (current-buffer)
                 when (fstar-subp-tracking-overlay-p overlay)
                 when (or (not status) (fstar-subp-status-eq overlay status))
                 collect overlay)
        (lambda (o1 o2) (< (overlay-start o1) (overlay-start o2)))))

(defun fstar-subp-issue-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp issue overlay."
  (overlay-get overlay 'fstar-subp-issue))

(defun fstar-subp-issues-overlays ()
  "Find all -subp issues overlays in the current buffer."
  (cl-loop for overlay being the overlays of (current-buffer)
           when (fstar-subp-issue-overlay-p overlay)
           collect overlay))

(defun fstar-subp-read-only-hook (&rest _args)
  "Prevent modifications."
  (unless inhibit-read-only
    (error "Region is read-only")))
(add-to-list 'debug-ignored-errors "Region is read-only")

(defun fstar-subp-set-status (overlay status)
  "Set status of OVERLAY to STATUS."
  (fstar-assert (memq status fstar-subp-statuses))
  (let ((inhibit-read-only t)
        (face-name (concat "fstar-subp-overlay-" (symbol-name status) "-face")))
    (overlay-put overlay 'fstar-subp-status status)
    (overlay-put overlay 'priority -1) ;;FIXME this is not an allowed value
    (overlay-put overlay 'face (intern face-name))
    (overlay-put overlay 'insert-in-front-hooks '(fstar-subp-read-only-hook))
    (overlay-put overlay 'modification-hooks '(fstar-subp-read-only-hook))))

(defun fstar-subp-process-overlay (overlay)
  "Send the contents of OVERLAY to the underlying F* process."
  (fstar-assert (not fstar-subp--busy-now))
  (fstar-subp-set-status overlay 'busy)
  (setq fstar-subp--busy-now overlay)
  (fstar-subp-send-region (overlay-start overlay) (overlay-end overlay)))

(defun fstar-subp-process-queue ()
  "Process the next pending overlay, if any."
  (unless fstar-subp--busy-now
    (-if-let* ((overlay (car-safe (fstar-subp-tracking-overlays 'pending))))
        (progn (fstar-subp-log "Processing queue")
               (fstar-subp-process-overlay overlay))
      (fstar-subp-log "Queue is empty"))))

(defun fstar-subp-unprocessed-beginning ()
  "Find the beginning of the unprocessed buffer area."
  (or (cl-loop for overlay in (fstar-subp-tracking-overlays)
               maximize (overlay-end overlay))
      (point-min)))

(defun fstar-skip-spaces-backwards-from (point)
  "Go to POINT, skip spaces backwards, and return position."
  (save-excursion
    (goto-char point)
    (skip-chars-backward "\n\r\t ")
    (point)))

(defun fstar-subp-enqueue-until (end &optional no-error)
  "Mark region up to END busy, and enqueue the newly created overlay.

If NO-ERROR is set, do not report an error if the region is empty."
  (let ((beg (fstar-subp-unprocessed-beginning))
        (end (fstar-skip-spaces-backwards-from end)))
    (fstar-assert (cl-loop for overlay in (overlays-in beg end)
                     never (fstar-subp-tracking-overlay-p overlay)))
    (if (<= end beg)
        (unless no-error
          (user-error "Nothing to process!"))
      (let ((overlay (make-overlay beg end (current-buffer) nil nil)))
        (fstar-subp-set-status overlay 'pending)
        (fstar-subp-process-queue)))))

(defcustom fstar-subp-block-sep "\\(\\'\\|\\s-*\\(\n\\s-*\\)\\{3,\\}\\)" ;; FIXME add magic comment
  "Regular expression used when looking for source blocks."
  :group 'fstar) ;; FIXME group fstar-interactive

(defun fstar-subp-skip-comments-and-whitespace ()
  "Skip over comments and whitespace."
  (while (or (> (skip-chars-forward " \r\n\t") 0)
             (comment-forward 1))))

(defun fstar-subp-advance-next ()
  "Process buffer until `fstar-subp-block-sep'."
  (interactive)
  (goto-char (fstar-subp-unprocessed-beginning))
  (fstar-subp-skip-comments-and-whitespace)
  (-if-let* ((next-start (re-search-forward fstar-subp-block-sep nil t)))
      (fstar-subp-enqueue-until next-start)
    (user-error "Cannot find a full block to process")))

(defun fstar-subp-pop-overlay (overlay)
  "Remove overlay OVERLAY and issue the corresponding #pop command."
  (fstar-assert (not fstar-subp--busy-now))
  (process-send-string fstar-subp--process fstar-subp--cancel)
  (delete-overlay overlay))

(defun fstar-subp-retract-one (overlay)
  "Retract OVERLAY, with some error checking."
  (cond
   ((not overlay) (user-error "Nothing to retract"))
   ((fstar-subp-status-eq overlay 'pending) (delete-overlay overlay))
   ((fstar-subp-status-eq overlay 'busy) (user-error "Cannot retract busy region"))
   ((fstar-subp-status-eq overlay 'processed) (fstar-subp-pop-overlay overlay))))

(defun fstar-subp-retract-last ()
  "Retract last processed block."
  (interactive)
  (fstar-subp-retract-one (car-safe (last (fstar-subp-tracking-overlays)))))

(defun fstar-subp-retract-until (pos)
  "Retract blocks until POS is in unprocessed region."
  (cl-loop for overlay in (reverse (fstar-subp-tracking-overlays))
           when (>= (overlay-end overlay) pos)
           do (fstar-subp-retract-one overlay)))

(defun fstar-subp-advance-until (pos)
  "Submit or retract blocks to/from prover until POS."
  (save-excursion
    (goto-char (fstar-subp-unprocessed-beginning))
    (let ((found (cl-loop do (fstar-subp-skip-comments-and-whitespace)
                          while (and (< (point) pos) (re-search-forward fstar-subp-block-sep pos t))
                          do (fstar-subp-enqueue-until (point))
                          collect (point))))
      (fstar-subp-enqueue-until pos found))))

(defun fstar-subp-advance-or-retract-to-point ()
  "Advance or retract proof state to reach point."
  (interactive)
  (let ((limit (fstar-subp-unprocessed-beginning)))
    (cond
     ((<= (point) limit) (fstar-subp-retract-until (point)))
     ((>  (point) limit) (fstar-subp-advance-until (point))))))

(defun fstar-setup-interactive ()
  ;; TODO discuss these keybindings
  "Setup interactive F* mode."
  (define-key fstar-mode-map (kbd "C-c C-n") #'fstar-subp-advance-next)
  (define-key fstar-mode-map (kbd "C-c C-u") #'fstar-subp-retract-last)
  (define-key fstar-mode-map (kbd "C-c C-p") #'fstar-subp-retract-last)
  (define-key fstar-mode-map (kbd "C-c <C-return>") #'fstar-subp-advance-or-retract-to-point)
  (flycheck-mode -1))

;;; Comment syntax

(defun fstar-syntactic-face-function-aux (_ _b _c in-string comment-depth _d _e _f comment-start-pos _g)
  "Choose face to display.

Arguments IN-STRING COMMENT-DEPTH and COMMENT-START-POS ar as in
`font-lock-syntactic-face-function'."
  (cond (in-string font-lock-string-face)
        ((and comment-depth
              comment-start-pos
              (numberp comment-depth))
         (save-excursion
           (goto-char comment-start-pos)
           (cond
            ((looking-at (regexp-quote fstar-build-config-header)) font-lock-doc-face)
            ((looking-at (regexp-quote "(*** ")) '(:inherit font-lock-doc-face :height 2.5))
            ((looking-at (regexp-quote "(**+ ")) '(:inherit font-lock-doc-face :height 1.8))
            ((looking-at (regexp-quote "(**! ")) '(:inherit font-lock-doc-face :height 1.5))
            ((looking-at (regexp-quote "(** "))  font-lock-doc-face)
            (t font-lock-comment-face))))))

(defun fstar-syntactic-face-function (args)
  (apply #'fstar-syntactic-face-function-aux args))

(defun fstar-setup-comments ()
  "Set comment-related variables for F*."
  (setq-local comment-start      "(*")
  (setq-local comment-end        "*)")
  (setq-local comment-start-skip "\\s-*(\\*+\\s-**")
  (setq-local comment-end-skip   "\\s-*\\*+)\\s-*")
  (setq-local font-lock-syntactic-face-function #'fstar-syntactic-face-function))

;;; Main mode

(defcustom fstar-enabled-modules
  '(font-lock prettify indentation comments flycheck interactive)
  "Which F* mode modules to load."
  :group 'fstar)

;;;###autoload
(define-derived-mode fstar-mode prog-mode "F✪"
  :syntax-table fstar-syntax-table
  (dolist (module fstar-enabled-modules)
    (funcall (intern (concat "fstar-setup-" (symbol-name module))))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fs[ity]\\'" . fstar-mode))

;;; Footer

(provide 'fstar-mode)
;;; fstar-mode.el ends here
