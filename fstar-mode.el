;;; fstar-mode.el --- Support for F* programming -*- lexical-binding: t; indent-tabs-mode: nil -*-

;; Copyright (C) 2015-2017 Clément Pit-Claudel
;; Author: Clément Pit-Claudel <clement.pitclaudel@live.com>
;; URL: https://github.com/FStarLang/fstar-mode.el

;; Created: 27 Aug 2015
;; Version: 0.4
;; Package-Requires: ((emacs "24.3") (dash "2.11") (company "0.8.12") (quick-peek "1.0") (yasnippet "0.11.0")  (flycheck "30.0") (company-quickhelp "2.2.0"))
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

;; This file implements support for F* programming in Emacs, including:
;;
;; * Syntax highlighting
;; * Unicode math (prettify-symbols-mode)
;; * Documentation and search
;; * Relative indentation
;; * Outlining and selective display
;; * Type hints (Eldoc)
;; * Autocompletion (Company)
;; * Type-aware snippets (Yasnippet)
;; * Interactive proofs (à la Proof-General)
;; * Real-time verification (Flycheck)
;; * Remote editing (Tramp)
;;
;; See https://github.com/FStarLang/fstar-mode.el for setup and usage tips.

;;; Code:

;;; Imports

(require 'cl-lib)
(require 'json)
(require 'eldoc)
(require 'help-at-pt)
(require 'ansi-color)
(require 'easymenu)
(require 'tramp)
(require 'tramp-sh)
(require 'crm)
(require 'tool-bar)
(require 'notifications nil t)
;; replace.el doesn't `provide' in Emacs < 26
(ignore-errors (require 'replace))

(require 'dash)
(require 'company)
(require 'quick-peek)
(require 'yasnippet)
(require 'flycheck)
(require 'let-alist)
(require 'company-quickhelp)

(defconst fstar--script-full-path
  (or (and load-in-progress load-file-name)
      (bound-and-true-p byte-compile-current-file)
      (buffer-file-name))
  "Full path of this script.")

(defconst fstar--directory
  (file-name-directory fstar--script-full-path)
  "Full path to directory of this script.")

;;; Compatibility with older Emacsen

(defmacro fstar-assert (&rest args)
  "Call `cl-assert' on ARGS, if available."
  (declare (debug t))
  `(when (fboundp 'cl-assert)
     (cl-assert ,@args)))

(eval-and-compile
  (unless (featurep 'subr-x)
    (defsubst string-trim-left (string)
      "Remove leading whitespace from STRING."
      (if (string-match "\\`[ \t\n\r]+" string)
          (replace-match "" t t string)
        string))
    (defsubst string-trim-right (string)
      "Remove trailing whitespace from STRING."
      (if (string-match "[ \t\n\r]+\\'" string)
          (replace-match "" t t string)
        string)))
  (unless (fboundp 'prog-widen)
    (defalias 'prog-widen 'widen)))

(defun fstar--string-trim (s)
  "Trim S, or return nil if nil."
  (when s (string-trim-left (string-trim-right s))))

;;; Customization

(defgroup fstar nil
  "F* mode."
  :group 'languages)

(defgroup fstar-literate nil
  "Literate programming support for F* mode."
  :group 'fstar)

(defgroup fstar-interactive nil
  "Interactive proofs."
  :group 'fstar)

(defgroup fstar-tactics nil
  "Tactics and tactic-based proofs."
  :group 'fstar-interactive)

(defvaralias 'flycheck-fstar-executable 'fstar-executable)
(make-obsolete-variable 'flycheck-fstar-executable 'fstar-executable "0.2" 'set)

(defcustom fstar-executable "fstar.exe"
  "Where to find F*.
May be either “fstar.exe” (search in $PATH) or an absolute path."
  :group 'fstar
  :type 'file
  :risky t)

(defcustom fstar-smt-executable "z3"
  "Where to find the SML solver.
May be one of “z3” (search in $PATH), an absolute path, or a
function taking a string (the full path to the F* executable) and
returning a string (the full path to the SMT solver)."
  :group 'fstar
  :type 'file
  :risky t)

(defvaralias 'flycheck-fstar-literate-executable 'fstar-python-executable)

(defcustom fstar-python-executable "python"
  "Where to find Python (preferably 3).
Can be \"python\" or \"python3\", or an absolute path."
  :group 'fstar
  :type 'file
  :risky t)

(defconst fstar-known-modules
  '((font-lock         . "Syntax highlighting")
    (prettify          . "Unicode math (e.g. display forall as ∀; requires emacs 24.4 or later)")
    (subscripts        . #("Pretty susbcripts (e.g. display x1 as x1)" 39 40 (display (raise -0.3))))
    (indentation       . "Indentation (relative to previous lines)")
    (comments          . "Comment syntax and special comments ('(***', '(*+', etc.)")
    (flycheck          . "Real-time verification with Flycheck.")
    (interactive       . "Interactive verification (à la Proof-General).")
    (eldoc             . "Type annotations in the minibuffer.")
    (company           . "Completion with company-mode.")
    (company-defaults  . "Opinionated company-mode configuration.")
    (spinner           . "Blink the modeline while F* is busy.")
    (notifications     . "Show a notification when a proof completes.")
    (literate          . "Prettify “///” comment markers.")
    (literate-flycheck . "Real-time syntax-checking for literate comments.")
    (overlay-legend    . "Show a legend in the modeline when hovering an F* overlay.")
    (tool-bar          . "Customize the toolbar for interactive use of F*.")
    (auto-insert       . "Support for `auto-insert-mode'."))
  "Available components of F*-mode.")

(defcustom fstar-enabled-modules
  '(font-lock prettify subscripts indentation comments flycheck interactive
              eldoc company company-defaults spinner notifications
              literate literate-flycheck overlay-legend tool-bar auto-insert)
  "Which F*-mode components to load."
  :group 'fstar
  :type `(set ,@(cl-loop for (mod . desc) in fstar-known-modules
                         collect `(const :tag ,desc ,mod))))

;;; Type definitions

;; `fstar-location' must be defined early to reference it in `cl-typecase'

(cl-defstruct fstar-location
  filename line-from line-to col-from col-to)

(defun fstar--expand-file-name-on-remote (path)
  "Expand PATH and add Tramp's prefix to it if needed."
  (setq path (expand-file-name path))
  (if (file-remote-p path) path
    (concat (or (fstar--remote-p) "") path)))

(defun fstar-location-remote-filename (loc)
  "Expand LOC's filename and add Tramp's prefix to it if needed."
  (fstar--expand-file-name-on-remote (fstar-location-filename loc)))

(defun fstar--loc-to-string (loc)
  "Turn LOC into a string."
  (format "%s(%d,%d-%d,%d)"
          (fstar-location-remote-filename loc)
          (fstar-location-line-from loc)
          (fstar-location-col-from loc)
          (fstar-location-line-to loc)
          (fstar-location-col-to loc)))

(defun fstar-location-beg-offset (location)
  "Compute LOCATION's beginning offset in the current buffer."
  (fstar--line-col-offset (fstar-location-line-from location)
                     (fstar-location-col-from location)))

(defun fstar-location-end-offset (location)
  "Compute LOCATION's end offset in the current buffer."
  (fstar--line-col-offset (fstar-location-line-to location)
                     (fstar-location-col-to location)))

(cl-defstruct fstar-continuation
  id body start-time)

(defun fstar-continuation--delay (continuation)
  "Return the time elapsed since CONTINUATION was created."
  (time-since (fstar-continuation-start-time continuation)))

;;; Utilities

(defconst fstar--spaces "\t\n\r ")

(defun fstar--indent-str (str amount &optional skip-first-line)
  "Indent all lines of STR by AMOUNT.
If AMOUNT is a string, use that as indentation.
With SKIP-FIRST-LINE, don't indent the first one."
  (let ((indent (if (stringp amount) amount (make-string amount ?\s))))
    (if skip-first-line
        (replace-regexp-in-string "\n" (concat "\n" indent) str)
      (replace-regexp-in-string "^" indent str))))

(defun fstar--property-range (pos prop)
  "Find range around POS with consistent non-nil value of PROP."
  (let* ((val-1 (get-text-property (1- pos) prop))
         (val (get-text-property pos prop)))
    (when (or val val-1)
      (list (if (eq (or val val-1) val-1)
                (previous-single-property-change pos prop) pos)
            (if val
                (next-single-property-change pos prop) pos)
            (or val val-1)))))

(defun fstar--expand-snippet (&rest args)
  "Ensure that Yasnippet is on and forward ARGS to `yas-expand-snippet'."
  (unless yas-minor-mode (yas-minor-mode 1))
  (let ((yas-indent-line nil))
    (apply #'yas-expand-snippet args)))

(defun fstar--refresh-eldoc ()
  "Tell Eldoc to do its thing.
It's often incorrect to add commands to `eldoc-message-commands',
as that leads to outdated information being displayed when the
command is asynchronous.  For example, adding
`fstar-insert-match-dwim' to `eldoc-message-commands' causes
eldoc to show the type of the hole *before* destruction, not
after."
  (eldoc-print-current-symbol-info))

(defun fstar--unwrap-paragraphs (str)
  "Remove hard line wraps from STR."
  (replace-regexp-in-string " *\n\\([^\n\t ]\\)" " \\1" str))

(defun fstar--strip-newlines (str)
  "Remove all newlines from STR."
  (replace-regexp-in-string " *\n *" " " str))

(defun fstar--resolve-fn-value (fn-or-v)
  "Return FN-OR-V, or the result of calling it if it's a function."
  (if (functionp fn-or-v)
      (funcall fn-or-v)
    fn-or-v))

(defun fstar--remote-p ()
  "Check if current buffer is remote.
Return a file name prefix if so, and nil otherwise."
  (file-remote-p (or buffer-file-name default-directory)))

(defun fstar--local-p ()
  "Check if current buffer is local."
  (not (fstar--remote-p)))

(defun fstar--maybe-cygpath (path)
  "Translate PATH using Cygpath if appropriate."
  (if (and (eq system-type 'cygwin) (fstar--local-p))
      (string-trim-right (car (process-lines "cygpath" "-w" path)))
    path))

(defun fstar--hide-buffer (buf)
  "Hide window displaying BUF, if any.
Return value indicates whether a window was hidden."
  (-when-let* ((doc-wins (and (buffer-live-p (get-buffer buf))
                              (get-buffer-window-list buf nil t))))
    (mapc (apply-partially #'quit-window nil) doc-wins)
    t))

(defun fstar--read-string (prompt default)
  "Read a string with PROMPT and DEFAULT.
Prompt should have one string placeholder to accommodate DEFAULT."
  (let ((default-info (if default (format " (default ‘%s’)" default) "")))
    (setq prompt (format prompt default-info)))
  (read-string prompt nil nil default))

(defun fstar--syntax-ppss (&optional pos)
  "Like `syntax-ppss' at POS, but don't move point."
  ;; This can be called in a narrowed buffer by `blink-matching-open'.
  (save-match-data (save-excursion (syntax-ppss pos))))

(defun fstar-in-comment-p (&optional pos)
  "Return non-nil if POS is inside a comment."
  (nth 4 (fstar--syntax-ppss pos)))

(defconst fstar--literate-comment-re "^///\\( \\|$\\)"
  "Regexp matching literate comment openers.")

(defun fstar-in-literate-comment-p (&optional pos)
  "Return non-nil if POS is inside a literate comment."
  (save-excursion
    (goto-char (or pos (point)))
    (goto-char (point-at-bol))
    (looking-at-p fstar--literate-comment-re)))

(defun fstar--column-in-commment-p (column)
  "Return non-nil if point at COLUMN is inside a comment."
  (save-excursion
    (move-to-column column)
    (fstar-in-comment-p)))

(defvar fstar--syntax-table-for--delimited-by
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\" "." table)
    table))

(defun fstar--delimited-by-p (delim pos limit)
  "Check if POS is enclosed in DELIM before LIMIT."
  (let ((found nil))
    (save-restriction
      (narrow-to-region limit (point-max))
      (with-syntax-table fstar--syntax-table-for--delimited-by
        (while (and (not found)
                    (setq pos (ignore-errors (scan-lists pos -1 1))))
          (setq found (eq (char-after pos) delim)))))
    found))

(defun fstar--in-string-p (&optional pos)
  "Check if POS is in a string.
This doesn't work for strings in snippets inside of comments."
  (nth 3 (fstar--syntax-ppss pos)))

(defun fstar--in-code-p (&optional pos)
  "Check if POS is in a code fragment (possibly embedded in a comment)."
  (let* ((sx (fstar--syntax-ppss pos))
         (in-comment (nth 4 sx)))
    (or (not in-comment)
        (and
         (not (fstar-in-literate-comment-p))
         (save-excursion
           (when pos (goto-char pos))
           (let ((comment-beg (nth 8 sx)))
             (fstar--delimited-by-p
              ?\[ (point) (max comment-beg (point-at-bol)))))))))

(defun fstar-subp--column-number-at-pos (pos)
  "Return column number at POS."
  (save-excursion (goto-char pos) (- (point) (point-at-bol))))

(defun fstar--goto-line-col (line &optional column)
  "Go to position indicated by LINE, COLUMN."
  (goto-char (point-min))
  (forward-line (1- line))
  (when column
    ;; min makes sure that we don't spill to the next line.
    (forward-char (min (- (point-at-eol) (point-at-bol)) column))))

(defun fstar--line-col-offset (line column)
  "Convert a (LINE, COLUMN) pair into a buffer offset."
  ;; LATER: This would be much easier if the interactive mode returned
  ;; an offset instead of a line an column.
  (save-excursion
    (fstar--goto-line-col line column)
    (point)))

(defun fstar--match-strings-no-properties (ids &optional str)
  "Get (match-string-no-properties ID STR) for each ID in IDS."
  (mapcar (lambda (num) (match-string-no-properties num str)) ids))

(defvar fstar--fqn-at-point-syntax-table)

(defun fstar--fqn-at-point (&optional pos)
  "Return symbol at POS (default: point)."
  (setq pos (or pos (point)))
  (with-syntax-table fstar--fqn-at-point-syntax-table
    (save-excursion
      (goto-char pos)
      (-when-let* ((s (thing-at-point 'symbol t)))
        (replace-regexp-in-string ;; Drop final "." from e.g. A.B.(xy)
         "\\.\\'" "" s)))))

(defun fstar--propertize-title (title)
  "Format TITLE as a title."
  (propertize title 'face '(:height 1.5)))

(defun fstar--push-mark ()
  "Save current position in mark ring and xref stack."
  (push-mark nil t)
  (when (fboundp 'xref-push-marker-stack)
    (xref-push-marker-stack)))

(defun fstar--navigate-to-parse-display-action (display-action)
  "Convert DISPLAY-ACTION into an argument to `display-buffer'."
  (pcase display-action
    (`nil '((display-buffer-same-window)))
    (`reuse '((display-buffer-reuse-window display-buffer-same-window)))
    (`window '((display-buffer-reuse-window display-buffer-pop-up-window)
               (reusable-frames . 0)
               (inhibit-same-window . t)))
    (`frame '((display-buffer-reuse-window display-buffer-pop-up-frame)
              (reusable-frames . 0)
              (inhibit-same-window . t)))))

(defun fstar--highlight-region (beg end)
  "Pulse BEG..END.
If END is nil, pulse the entire line containing BEG."
  (if end
      (when (fboundp 'pulse-momentary-highlight-region)
        (pulse-momentary-highlight-region beg end))
    (when (fboundp 'pulse-momentary-highlight-one-line)
      (pulse-momentary-highlight-one-line beg))))

(defvar-local fstar--parent-buffer nil
  "The buffer that opened the current buffer, if it exists.
This is relevant when (for example) a user jumps to the current
buffer using a 'jump to definition' command.  If it is set, then
this buffer may be used to run F* queries if an F* process isn't
started in the current buffer.")

(defun fstar--navigate-to-1 (location display-action switch)
  "Navigate to LOCATION.
DISPLAY-ACTION determines where the resulting buffer is
shown (nil for the currently selected window, `reuse' for the
current window unless another one is already showing the buffer,
`window' for a separate window, and `frame' for a separate
frame).  SWITCH determines whether the resulting buffer and
window become current and selected."
  (fstar--push-mark)
  (let ((fname (fstar-location-remote-filename location))
        (line (fstar-location-line-from location))
        (col (fstar-location-col-from location))
        (line-to (fstar-location-line-to location))
        (col-to (fstar-location-col-to location))
        (action (fstar--navigate-to-parse-display-action display-action)))
    (if (not (file-exists-p fname))
        (message "File not found: %S" fname)
      (-when-let* ((buf (find-file-noselect fname))
                   (parent-buf (or fstar--parent-buffer (current-buffer)))
                   (win (if (not switch)
                            (display-buffer buf action)
                          (when (eq (pop-to-buffer buf action)
                                    (window-buffer (selected-window)))
                            (selected-window)))))
        (with-selected-window win
          (with-current-buffer buf ;; FIXME check this
            (push-mark (point) t) ;; Save default position in mark ring
            (setq fstar--parent-buffer parent-buf)
            (fstar--goto-line-col (or line 1) col)
            (recenter)
            (when line
              (let ((end (and line-to (fstar--line-col-offset line-to col-to))))
                (fstar--highlight-region (point) end)))))))))

(defun fstar--navigate-to (target &optional display-action)
  "Jump to TARGET, a location or a path.
DISPLAY-ACTION: see `fstar--navigate-to-1'."
  (fstar--navigate-to-1
   (cl-etypecase target
     (fstar-location target)
     (string (make-fstar-location
              :filename target
              :line-from nil :line-to nil
              :col-from nil :col-to nil)))
   display-action t))

(defun fstar--visit-link-target (marker)
  "Jump to file indicated by entry at MARKER."
  (let* ((pos (marker-position marker))
         (buf (marker-buffer marker))
         (target (get-text-property pos 'fstar--target buf))
         (display-action (get-text-property pos 'fstar--display-action buf)))
    (fstar--navigate-to target display-action)))

(defun fstar--insert-link (target face &optional label display-action)
  "Insert a link to TARGET with LABEL and FACE.
TARGET is either a string or a location.
DISPLAY-ACTION: see `fstar--navigate-to-1'."
  (let ((label (or label
                   (cl-typecase target
                     (string target)
                     (fstar-location (fstar--loc-to-string target))))))
    (insert-text-button label 'fstar--target target
                        'face face 'follow-link t
                        'action 'fstar--visit-link-target
                        'fstar--display-action display-action)))

(defun fstar--lispify-null (x)
  "Return X, or nil if X is `:json-null'."
  (unless (eq x :json-null) x))

(defun fstar--lispify-false (x)
  "Return X, or nil if X is `:json-false'."
  (unless (eq x :json-false) x))

(defun fstar--comment-beginning (pos)
  "Return point before start of comment at POS."
  (nth 8 (fstar--syntax-ppss pos)))

(defun fstar--search-predicated-1 (search-fn test-fn move-fn re bound)
  "Helper for `fstar--search-predicated'.
SEARCH-FN, TEST-FN, MOVE-FN, RE, BOUND: see `fstar--search-predicated'."
  (catch 'found
    (while (funcall search-fn re bound t)
      (when (funcall test-fn)
        (throw 'found (point)))
      (when (= (match-beginning 0) (match-end 0))
        (unless (funcall move-fn)
          (throw 'found nil))))
    (throw 'found nil)))

(defun fstar--search-predicated (search-fn test-fn move-fn re bound)
  "Use SEARCH-FN to find matches of RE before BOUND satisfying TEST-FN.
MOVE-FN is used to move the point when TEST-FN returns nil and
the match is empty.  Return non-nil if RE can be found.  This
function does not move the point."
  (save-excursion
    (comment-normalize-vars)
    (and (fstar--search-predicated-1 search-fn test-fn move-fn re bound)
         ;; Ensure that the match is maximal when searching backwards for
         ;; e.g. \n+ in a buffer containing \n•\n
         (goto-char (match-beginning 0))
         (looking-at re))))

(defun fstar--adjust-point-forward ()
  "Move point forward and return a boolean indicating success."
  (unless (eobp) (forward-char) t))

(defun fstar--search-predicated-forward (test-fn needle &optional bound)
  "Search forward for matches of NEEDLE before BOUND satisfying TEST-FN."
  (when (fstar--search-predicated #'search-forward test-fn
                             #'fstar--adjust-point-forward needle bound)
    (goto-char (match-end 0))))

(defun fstar--re-search-predicated-forward (test-fn re &optional bound)
  "Search forward for matches of RE before BOUND satisfying TEST-FN."
  (when (fstar--search-predicated #'re-search-forward test-fn
                             #'fstar--adjust-point-forward re bound)
    (goto-char (match-end 0))))

(defun fstar--adjust-point-backward ()
  "Move point backward and return a boolean indicating success."
  (unless (bobp) (backward-char) t))

(defun fstar--re-search-predicated-backward (test-fn re &optional bound)
  "Search backwards for matches of RE before BOUND satisfying TEST-FN."
  (when (fstar--search-predicated #'re-search-backward test-fn
                             #'fstar--adjust-point-backward re bound)
    (goto-char (match-beginning 0))))

(defmacro fstar--widened (&rest body)
  "Run BODY widened."
  (declare (indent 0) (debug t))
  `(save-restriction (widen) ,@body))

(defmacro fstar--widened-excursion (&rest body)
  "Run BODY widened in a `save-excursion' block."
  (declare (indent 0) (debug t))
  `(save-excursion (fstar--widened ,@body)))

(defmacro fstar--prog-widened-excursion (&rest body)
  "Run BODY widened in a `save-excursion' block."
  (declare (indent 0) (debug t))
  `(save-excursion (save-restriction (prog-widen) ,@body)))

(defun fstar--specified-space-to-align-right (str &optional padding)
  "Compute a specified space to align STR PADDING spaces away from the right."
  (let ((str-width (string-width str)))
    (propertize " " 'display `(space :align-to (- right ,str-width ,(or padding 0))))))

(defun fstar--insert-with-face (face fmt &rest args)
  "Insert (format FMT args) with FACE.
With no ARGS, just insert FMT."
  (declare (indent 2))
  (let ((beg (point)))
    (insert (if args (apply #'format fmt args) fmt))
    (font-lock-append-text-property beg (point) 'face face)))

(defun fstar--insert-ln-with-face (face fmt &rest args)
  "Insert (format FMT args) with FACE and add a newline.
With no ARGS, just insert FMT and a newline."
  (declare (indent 2))
  (apply #'fstar--insert-with-face face fmt args)
  (insert "\n"))

(defun fstar--set-text-props (str &rest props)
  "Set text properties on STR to PROPS."
  (set-text-properties 0 (length str) props str))

(defun fstar--truncate-left (str maxlen)
  "Truncate STR from the start to MAXLEN characters."
  (let* ((strlen (length str))
         (ntrunc (- strlen maxlen)))
    (if (<= ntrunc 0) str
      (concat "…" (substring str (1+ ntrunc) strlen)))))

;;; Debugging

(define-obsolete-variable-alias 'fstar-subp-debug 'fstar-debug "0.4")

(defvar fstar-debug nil
  "If non-nil, print debuging information in interactive mode.")

(define-obsolete-function-alias 'fstar-subp-toggle-debug 'fstar-toggle-debug "0.4")

(defun fstar-toggle-debug ()
  "Toggle `fstar-debug'."
  (interactive)
  (message "F*: Debugging %s."
           (if (setq-default fstar-debug (not fstar-debug)) "enabled" "disabled"))
  (when fstar-debug
    (display-buffer (fstar--log-buffer))))

(defconst fstar--log-buffer-keywords
  '(("!!!" . font-lock-warning-face)
    (">>>" . font-lock-constant-face)
    ("\\(;;;\\)\\(.*\\)"
     (1 font-lock-constant-face prepend)
     (2 font-lock-comment-face prepend))
    ("^#done-n?ok" . font-lock-builtin-face)))

(defun fstar--log-buffer ()
  "Get or create log buffer."
  (or (get-buffer "*fstar-debug*")
      (with-current-buffer (get-buffer-create "*fstar-debug*")
        (setq-local truncate-lines t)
        (setq-local window-point-insertion-type t)
        (setq-local font-lock-defaults '(fstar--log-buffer-keywords))
        (font-lock-mode 1)
        (buffer-disable-undo)
        (current-buffer))))

(defun fstar--log (kind format &rest args)
  "Log a message of kind KIND, conditional on `fstar-debug'.

FORMAT and ARGS are as in `message'.
LEVEL is one of `info', `input', `output'."
  (with-current-buffer (fstar--log-buffer)
    (goto-char (point-max))
    (let* ((raw (apply #'format format args))
           (head (cdr (assq kind '((info . ";;; ") (in . ">>> ")
                                   (warning . "!!! ") (out . ""))))))
      (fstar-assert head)
      (insert (fstar--indent-str raw head)
              (if (eq kind 'out) "" "\n")))))

(defmacro fstar-log (kind format &rest args)
  "Log a message of kind KIND, conditional on `fstar-debug'.

FORMAT and ARGS are as in `message'."
  (declare (debug t))
  `(when fstar-debug
     (fstar--log ,kind ,format ,@args)))

(defun fstar--write-transcript-1 (fname lines)
  "Write (nreverse LINES) to FNAME."
  (with-temp-buffer
    (dolist (line (nreverse lines))
      (insert line "\n"))
    (write-region (point-min) (point-max) fname)))

(defun fstar-write-transcript-1 (prefix)
  "Write latest transcript in current buffer to PREFIX.IN and PREFIX.OUT."
  (interactive "FSave transcript as: ")
  (goto-char (point-max))
  (unless (re-search-backward "^;;; \n" nil t)
    (user-error "Could not find a complete transcript to save"))
  (let ((log (buffer-substring-no-properties (match-end 0) (point-max)))
        (exclude-re (concat "^" (regexp-opt '(">>> " "!!! " ";;; "))))
        (in nil) (out nil))
    (dolist (line (delete "" (split-string log "\n")))
      (cond
       ((string-match "^>>> " line)
        (push (substring line (match-end 0)) in))
       ((not (string-match-p exclude-re line))
        (unless (equal line "") (push line out)))))
    (fstar--write-transcript-1 (concat prefix ".in") in)
    (fstar--write-transcript-1 (concat prefix ".out") out)))

(defun fstar-write-transcript (prefix)
  "Write latest transcript to PREFIX.IN and PREFIX.OUT."
  (interactive "FSave transcript as: ")
  (unless fstar-debug
    (user-error "Use `fstar-toggle-debug' to collect traces"))
  (with-current-buffer (fstar--log-buffer)
    (fstar-write-transcript-1 prefix)))

;;; Compatibility across F* versions

(defvar-local fstar--vernum nil
  "F*'s version number.")

(defcustom fstar-assumed-vernum "0.9.4.3"
  "Version number to assume if F* returns an unknown version number.
This is useful when running an F#-compiled F*.  Use 42.0 to
enable all experimental features."
  :group 'fstar
  :type 'string)

(defconst fstar--features-min-version-alist
  '((absolute-linums-in-errors . "0.9.3.0-beta2")
    (lookup . "0.9.4.1")
    (info-includes-symbol . "0.9.4.2")
    (autocomplete . "0.9.4.2")
    (json-subp . "0.9.4.3")))

(defvar-local fstar--features nil
  "List of available F* features.")

(defun fstar--query-vernum (executable)
  "Ask F* EXECUTABLE for its version number."
  (let ((fname buffer-file-name))
    (with-temp-buffer
      (let ((buffer-file-name fname)
            (exit-code (process-file executable nil t nil "--version")))
        (unless (equal exit-code 0)
          (error "Failed to check F*'s version: “%s”" (buffer-string))))
      (buffer-string))))

(defun fstar--init-compatibility-layer (executable)
  "Adjust compatibility settings based on EXECUTABLE's version number."
  (let* ((version-string (fstar--query-vernum executable)))
    (if (string-match "^F\\* \\([- .[:alnum:]]+\\)" version-string)
        (setq fstar--vernum (match-string 1 version-string))
      (let ((print-escape-newlines t))
        (message "F*: Can't parse version number from %S; assuming %s (\
don't worry about this if you're running an F#-based F* build)."
                 version-string fstar-assumed-vernum))
      (setq fstar--vernum "unknown")))
  (let ((vernum (if (equal fstar--vernum "unknown") fstar-assumed-vernum fstar--vernum)))
    (pcase-dolist (`(,feature . ,min-version) fstar--features-min-version-alist)
      (when (version<= min-version vernum)
        (push feature fstar--features)))))

(defun fstar--has-feature (feature &optional error-fn)
  "Check if FEATURE is available in the current F*.
If not, call ERROR-FN if supplied with a relevant message."
  (or (null fstar--vernum)
      (memq feature fstar--features)
      (ignore
       (and error-fn
            (funcall error-fn "This feature isn't available \
in your version of F*.  You're running version %s" fstar--vernum)))))

;;; Whole-buffer Flycheck

(defcustom fstar-flycheck-checker 'fstar-interactive
  "Which Flycheck checker to use in F*-mode."
  :group 'fstar
  :type '(choice (const :tag "No Flycheck support" nil)
                 (const :tag "Whole-buffer verification (slow)" fstar)
                 (const :tag "Lightweight typechecking (fast)" fstar-interactive)))

(make-variable-buffer-local 'fstar-flycheck-checker)

(defconst fstar-error-patterns
  (let* ((digits '(+ (any digit)))
         (line-col `("(" line "," column "-" ,digits "," ,digits ")")))
    `((error (file-name) ,@line-col ": (Error) " (message))
      (warning (file-name) ,@line-col ": (Warning) " (message)))))

(defun fstar--flycheck-verify-enabled (checker)
  "Create a verification result announcing whether CHECKER is enabled."
  (let ((enabled (eq fstar-flycheck-checker checker)))
    (list
     (flycheck-verification-result-new
      :label "Checker selection"
      :message (if enabled "OK, checker selected"
                 (format "Set ‘fstar-flycheck-checker’ \
to ‘%S’ to use this checker." checker))
      :face (if enabled 'success '(bold error))))))

(flycheck-define-command-checker 'fstar
  "Flycheck checker for F*."
  :command '("fstar.exe" source-inplace)
  :error-patterns fstar-error-patterns
  :error-filter #'flycheck-increment-error-columns
  :modes '(fstar-mode)
  :verify (apply-partially #'fstar--flycheck-verify-enabled)
  :predicate (lambda () (eq fstar-flycheck-checker 'fstar)))

(add-to-list 'flycheck-checkers 'fstar)

(defun fstar-setup-flycheck ()
  "Prepare Flycheck for use with F*."
  (flycheck-mode 1))

;;; Prettify symbols

(defcustom fstar-symbols-alist '(("exists" . ?∃) ("forall" . ?∀) ("fun" . ?λ)
                            ("nat" . ?ℕ) ("int" . ?ℤ)
                            ("True" . ?⊤) ("False" . ?⊥)
                            ("*" . ?×) (":=" . ?≔) ("::" . ?⸬)
                            ("<=" . ?≤) (">=" . ?≥) ("<>" . ?≠)
                            ("/\\" . ?∧) ("\\/" . ?∨) ("~" . ?¬) ("||" . ?‖)
                            ("<==>" . ?⟺) ("==>" . ?⟹) ;; ("<==" . ?⟸)
                            ("->" . ?→) ("~>" . ?↝) ("=>" . ?⇒)
                            ("<-" . ?←) ("<--" . ?⟵) ("-->" . ?⟶)
                            ("<<" . ?≪) ;; (">>" . ?≫)
                            ("<|" . ?◃) ("|>" . ?▹) ;; ("<||" . ?⧏) ("||>" . ?⧐)
                            ;; ("(|" . ?⦅) ("|)" . ?⦆)
                            ("'a" . ?α) ("'b" . ?β) ("'c" . ?γ)
                            ("'d" . ?δ) ("'e" . ?ε) ("'f" . ?φ)
                            ("'g" . ?χ) ("'h" . ?η) ("'i" . ?ι)
                            ("'k" . ?κ) ("'m" . ?μ) ("'n" . ?ν)
                            ("'p" . ?π) ("'q" . ?θ) ("'r" . ?ρ)
                            ("'s" . ?σ) ("'t" . ?τ) ("'u" . ?ψ)
                            ("'w" . ?ω) ("'x" . ?ξ) ("'z" . ?ζ))
  "F* symbols."
  :group 'fstar
  :type 'alist)

(defun fstar--same-ish-syntax (other ref)
  "Check if the syntax class of OTHER is similar to that of REF."
  (memq (char-syntax (or other ?\s))
        (if (memq (char-syntax ref) '(?w ?_))
            '(?w ?_)
          '(?. ?\\))))

(defun fstar--prettify-symbols-predicate (start end &optional _match)
  "Decide whether START..END should be prettified.
Differs from `prettify-symbols-default-compose-p' inasmuch as it
allows composition in code comments."
  (and (not (fstar--same-ish-syntax (char-before start) (char-after start)))
       (not (fstar--same-ish-syntax (char-after end) (char-before end)))
       ;; Test both endpoints because `syntax-ppss' doesn't include comment
       ;; openers in comments (i.e. the ‘*’ of ‘(*’ isn't in the comment).
       (not (fstar--in-string-p start))
       (not (fstar--in-string-p end))
       (fstar--in-code-p start)
       (fstar--in-code-p end)))

(defun fstar-setup-prettify ()
  "Setup prettify-symbols for use with F*."
  (when (and (boundp 'prettify-symbols-alist)
             (fboundp 'prettify-symbols-mode))
    (setq-local prettify-symbols-alist (append fstar-symbols-alist
                                               prettify-symbols-alist))
    (when (boundp 'prettify-symbols-compose-predicate)
      (setq prettify-symbols-compose-predicate #'fstar--prettify-symbols-predicate))
    (prettify-symbols-mode)))

;;; Font-Lock

(defconst fstar-syntax-headers
  '("open" "module" "include" "friend"
    "let" "let rec" "val" "and" "assume"
    "exception" "effect" "new_effect" "sub_effect" "new_effect_for_free" "layered_effect"
    "kind" "type" "class" "instance"))

(defconst fstar-syntax-fsdoc-keywords
  '("@author" "@summary"))

(defconst fstar-syntax-fsdoc-keywords-re
  (format "^[[:space:]]*\\(%s\\)\\_>" (regexp-opt fstar-syntax-fsdoc-keywords)))

(defconst fstar-syntax-preprocessor
  '("#set-options" "#reset-options" "#push-options" "#pop-options" "#restart-solver" "#light"))

(defconst fstar-syntax-qualifiers
  '("new" "abstract" "logic" "assume" "visible"
    "unfold" "irreducible" "inline_for_extraction" "noeq" "noextract" "unopteq"
    "private" "opaque" "total" "default" "reifiable" "reflectable"))

(defconst fstar-syntax-block-header-re
  (format "^\\(?:%s[ \n]\\)*%s "
          (regexp-opt fstar-syntax-qualifiers)
          (regexp-opt fstar-syntax-headers))
  "Regexp matching block headers.")

(defconst fstar-syntax-block-start-re
  (format "^\\(?:%s[ \n]\\)*\\(\\[@\\|%s \\)"
          (regexp-opt fstar-syntax-qualifiers)
          (regexp-opt (append (remove "and" fstar-syntax-headers)
                              fstar-syntax-preprocessor)))
  "Regexp matching starts of semantic blocks.")

(defconst fstar-syntax-block-delims
  `("begin" "end" "in"))

(defconst fstar-syntax-structure-re
  (regexp-opt (append fstar-syntax-block-delims
                      fstar-syntax-headers
                      fstar-syntax-qualifiers)
              'symbols))

(defconst fstar-syntax-preprocessor-re
  (regexp-opt fstar-syntax-preprocessor 'symbols))

(defconst fstar-syntax-keywords
  '("of" "by" "normalize_term"
    "forall" "exists"
    "assert" "assert_norm" "assert_spinoff" "assume"
    "fun" "function"
    "calc"
    "introduce" "eliminate" "returns"
    "try" "match" "when" "with"
    "if" "then" "else"
    "ALL" "All" "DIV" "Div" "EXN" "Ex" "Exn" "GHOST" "GTot" "Ghost"
    "Lemma" "PURE" "Pure" "Tot" "ST" "STATE" "St"
    "Unsafe" "Stack" "Heap" "StackInline" "Inline"))

(defconst fstar-syntax-keywords-re
  (regexp-opt fstar-syntax-keywords 'symbols))

(defconst fstar-syntax-builtins
  '("requires" "ensures" "modifies" "decreases" "attributes"
    "effect_actions"))

(defconst fstar-syntax-builtins-re
  (regexp-opt fstar-syntax-builtins 'symbols))

(defconst fstar-syntax-ambiguous-re
  (regexp-opt `("\\/" "/\\")))

(defconst fstar-syntax-constants
  '("False" "True"))

(defconst fstar-syntax-constants-re
  (regexp-opt fstar-syntax-constants 'symbols))

(defconst fstar-syntax-risky
  '("assume" "admit" "admitP" "magic" "unsafe_coerce" "sladmit" "tadmit" "tadmit_t" "admit1" "admit_all" "admit_dump" "magic_dump"))

(defconst fstar-syntax-risky-re
  (regexp-opt fstar-syntax-risky 'symbols))

(defconst fstar-syntax-reserved-exact-re
  (format "\\`%s\\'"
          (regexp-opt
           (append `("Type")
                   fstar-syntax-headers
                   fstar-syntax-fsdoc-keywords
                   fstar-syntax-preprocessor
                   fstar-syntax-qualifiers
                   fstar-syntax-block-delims
                   fstar-syntax-keywords
                   fstar-syntax-builtins
                   fstar-syntax-constants))))

(defface fstar-structure-face
  '((((background light)) (:bold t))
    (t :bold t :foreground "salmon"))
  "Face used to highlight structural keywords."
  :group 'fstar)

(defface fstar-risky-face
  '((t :underline t :inherit font-lock-warning-face))
  "Face used to highlight risky keywords (‘admit’ etc.)."
  :group 'fstar)

(defface fstar-subtype-face
  '((t :slant italic))
  "Face used to highlight subtyping clauses."
  :group 'fstar)

(defface fstar-attribute-face
  '((t :slant italic))
  "Face used to highlight attributes."
  :group 'fstar)

(defface fstar-decreases-face
  '((t :slant italic))
  "Face used to highlight decreases clauses."
  :group 'fstar)

(defface fstar-subscript-face
  '((t :height 1.0))
  "Face used to highlight subscripts"
  :group 'fstar)

(defface fstar-braces-face
  '((t))
  "Face to use for { and }."
  :group 'fstar)

(defface fstar-dereference-face
  '((t :inherit font-lock-negation-char-face))
  "Face to use for !."
  :group 'fstar)

(defface fstar-ambiguous-face
  '((t :inherit font-lock-negation-char-face))
  "Face to use for /\\ and \\/."
  :group 'fstar)

(defface fstar-universe-face
  '((t :foreground "forest green"))
  "Face used for universe levels and variables"
  :group 'fstar)

(defface fstar-operator-face
  '((t :inherit font-lock-variable-name-face))
  "Face used for backticked infix operators."
  :group 'fstar)

(defface fstar-literate-comment-face
  '((t :inherit default))
  "Face used for literate comments (///)."
  :group 'fstar-literate)

(defface fstar-literate-gutter-face
  '((t :inverse-video t :inherit font-lock-comment-face))
  "Face used for the fringe next to literate comments (///)."
  :group 'fstar-literate)

(defconst fstar-comment-start-skip "\\(//+\\|(\\*+\\)[ \t]*")

(defconst fstar-syntax-ws-re "\\(?:\\sw\\|\\s_\\)")
(defconst fstar-syntax-id-re (concat "\\_<[#']?[a-z_]" fstar-syntax-ws-re "*\\_>"))
(defconst fstar-syntax-cs-re (concat "\\_<[#']?[A-Z]" fstar-syntax-ws-re "*\\_>"))

(defconst fstar-syntax-id-with-subscript-re
  "\\_<[#']?_*[a-zA-Z]\\(?:[a-z0-9_']*[a-z]\\)?\\([0-9]+\\)['_]*\\_>")

(defconst fstar-syntax-universe-re (concat "\\_<u#\\(?:([^()]+)\\|" fstar-syntax-ws-re "*\\_>\\)"))

(defconst fstar-syntax-ids-re (concat "\\(" fstar-syntax-id-re "\\(?: +" fstar-syntax-id-re "\\)*\\)"))

(defconst fstar-syntax-ids-and-type-re (concat fstar-syntax-ids-re " *:"))

(defun fstar-find-id-maybe-type (bound must-find-type &optional extra-check)
  "Find var:type or var1..varN:type pair between point and BOUND.

If MUST-FIND-TYPE is nil, the :type part is not necessary.
If EXTRA-CHECK is non-nil, it is used as an extra filter on matches."
  (let ((found t) (rejected t)
        (regexp (if must-find-type fstar-syntax-ids-and-type-re fstar-syntax-ids-re)))
    (while (and found rejected)
      (setq found (re-search-forward regexp bound t))
      (setq rejected (and found (or (memq (char-after) '(?: ?=)) ; h :: t, h := t
                                    (not (fstar--in-code-p))
                                    (save-excursion
                                      (goto-char (match-beginning 0))
                                      (skip-syntax-backward "-")
                                      (or (and extra-check
                                               (not (funcall extra-check)))
                                          (eq (char-before) ?|) ;; | X: int
                                          (save-match-data
                                            ;; val x : Y:int
                                            (re-search-forward "\\_<\\(val\\|let\\|type\\)\\_>"
                                                               (match-end 0) t))))))))
    (when (and found must-find-type)
      (ignore-errors
        (goto-char (match-end 0))
        (forward-sexp)
        (let ((md (match-data)))
          (set-match-data `(,(car md) ,(point) ,@(cddr md))))))
    found))

(defvar-local fstar--font-lock-anchor nil)

(defun fstar--beginning-of-sexp (pos)
  "Find beginning of sexp enclosing POS."
  (or (nth 1 (fstar--syntax-ppss pos)) 1))

(defun fstar-subexpr-pre-matcher (rewind-to &optional bound-to)
  "Move past REWIND-TO th group, then return end of BOUND-TO th.
This also records the beginning of enclosing sexp in
`fstar--font-lock-anchor'."
  (setq-local fstar--font-lock-anchor (fstar--beginning-of-sexp (match-beginning 0)))
  (goto-char (match-end rewind-to))
  (match-end (or bound-to 0)))

(defun fstar--directly-under-anchor ()
  "Check whether point is directly under a binder.
This works by moving up in the sexp tree and checking that this
leads to the binder's start."
  (= (fstar--beginning-of-sexp (point)) (or fstar--font-lock-anchor 1)))

(defun fstar--find-formal (bound)
  "Find unparenthesized variable name between point and BOUND."
  (fstar-find-id-maybe-type bound nil #'fstar--directly-under-anchor))

(defun fstar-find-id-with-type (bound)
  "Find var:type pair between point and BOUND."
  (fstar-find-id-maybe-type bound t))

(defun fstar--search-forward-in-sexp (needle bound)
  "Find next NEEDLE at current level before BOUND or end of current sexp."
  (let ((fstar--font-lock-anchor (fstar--beginning-of-sexp (point))))
    (fstar--search-predicated-forward #'fstar--directly-under-anchor needle bound)))

(defun fstar--find-head-and-args (head tail bound)
  "Find HEAD .. TAIL expression between point and BOUND."
  (let ((found))
    (while (and (not found) (re-search-forward head bound t))
      (-when-let* ((mdata (match-data))
                   (fnd (fstar--search-forward-in-sexp tail (min bound (point-at-eol)))))
        (set-match-data `(,(car mdata) ,(match-end 0) ,@mdata))
        (setq found t)))
    found))

(defun fstar--find-fun-and-args (bound)
  "Find lambda expression between point and BOUND."
  (fstar--find-head-and-args "\\_<fun\\_>" "->" bound))

(defun fstar--find-quantifier-and-args (bound)
  "Find quantified expression between point and BOUND."
  (fstar--find-head-and-args "\\_<\\(?:forall\\|exists\\)\\_>" "." bound))

(defun fstar-find-subtype-annotation (bound)
  "Find {...} group between point and BOUND."
  (let ((found) (end))
    (while (and (not found) (re-search-forward "{[^:].*}" bound t))
      (setq end (save-excursion
                  (goto-char (match-beginning 0))
                  (ignore-errors (forward-sexp))
                  (point)))
      (setq found (and (<= end bound)
                       (<= end (point-at-eol))
                       (let ((prev-char (char-before (match-beginning 0))))
                         (or
                          (memq (char-syntax prev-char) '(?w ?_)) ;; a: int{ … }
                          (eq prev-char ?\))))))) ;; a: (int * int){ … }
    (when found
      (set-match-data `(,(1+ (match-beginning 0)) ,(1- end)))
      (goto-char end))
    found))

(defmacro fstar--fl-conditional-matcher (re cond)
  "Create a matcher for RE predicated on COND."
  `(apply-partially #'fstar--re-search-predicated-forward ,cond ,re))

(defconst fstar-syntax-additional
  (let ((id fstar-syntax-id-re))
    `((,fstar-syntax-cs-re
       (0 'font-lock-type-face))
      (,fstar-syntax-universe-re
       (0 'fstar-universe-face))
      (,(fstar--fl-conditional-matcher (concat "`" fstar-syntax-ws-re "+?`") #'fstar--in-code-p)
       (0 'fstar-operator-face append))
      (,(fstar--fl-conditional-matcher "`" #'fstar--in-code-p)
       (0 'font-lock-negation-char-face))
      (,fstar-syntax-fsdoc-keywords-re
       (1 'font-lock-constant-face prepend))
      (,(fstar--fl-conditional-matcher (concat "{\\(:" id "\\) *\\([^}]*\\)}") #'fstar--in-code-p)
       (1 'font-lock-builtin-face append)
       (2 'fstar-attribute-face append))
      (,(concat "\\_<\\(let\\(?: +rec\\)?\\|and\\)\\_>\\(\\(?: +" id "\\( *, *" id "\\)*\\)?\\)")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(concat "\\_<\\(type\\|kind\\|class\\|instance\\)\\( +" id "\\)")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(concat "\\_<\\(val\\) +\\(" id "\\) *:")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(fstar--fl-conditional-matcher fstar-syntax-block-header-re #'fstar--in-code-p)
       (0 'fstar-structure-face prepend))
      (fstar-find-id-with-type
       (1 'font-lock-variable-name-face append))
      (fstar-find-subtype-annotation
       (0 'fstar-subtype-face append))
      (,(fstar--fl-conditional-matcher "%\\[\\([^]]+\\)\\]" #'fstar--in-code-p)
       (1 'fstar-decreases-face append))
      (fstar--find-quantifier-and-args
       (1 'font-lock-keyword-face)
       (fstar--find-formal (fstar-subexpr-pre-matcher 1) nil (1 'font-lock-variable-name-face append)))
      (fstar--find-fun-and-args
       (1 'font-lock-keyword-face)
       (fstar--find-formal (fstar-subexpr-pre-matcher 1) nil (1 'font-lock-variable-name-face append)))
      (,(fstar--fl-conditional-matcher fstar-syntax-ambiguous-re #'fstar--in-code-p)
       (0 'fstar-ambiguous-face append))
      ("!"
       (0 'fstar-dereference-face))
      (,(fstar--fl-conditional-matcher "[{}]" #'fstar--in-code-p)
       (0 'fstar-braces-face append))
      (,fstar-syntax-risky-re
       (0 'fstar-risky-face prepend)))))

(defconst fstar--scratchpad-name " *%s-scratchpad*")

(defvar-local fstar--scratchpad nil
  "Temporary buffer used to highlight strings.")

(defun fstar--init-scratchpad ()
  "Get or create scratchpad buffer of current F* buffer."
  (unless (buffer-live-p fstar--scratchpad)
    (setq fstar--scratchpad
          (get-buffer-create (format fstar--scratchpad-name (buffer-name))))
    (with-current-buffer fstar--scratchpad
      (setq-local fstar-enabled-modules '(font-lock prettify))
      (flycheck-mode -1)
      (fstar-mode))))

(defun fstar--unparens (str)
  "Remove parentheses surrounding STR, if any."
  (if (and str
           (> (length str) 2)
           (eq (aref str 0) ?\()
           (eq (aref str (1- (length str))) ?\)))
      (substring str 1 (- (length str) 1))
    str))

(defun fstar--font-lock-ensure ()
  "Like `font-lock-flush'+`font-lock-ensure', but compatible with Emacs < 25."
  (if (and (fboundp 'font-lock-flush) (fboundp 'font-lock-ensure))
      (progn (font-lock-flush) (font-lock-ensure))
    (with-no-warnings (font-lock-fontify-buffer))))

(defun fstar-highlight-string (str)
  "Highlight STR as F* code."
  (fstar--init-scratchpad)
  (with-current-buffer fstar--scratchpad
    (erase-buffer)
    (insert str)
    (fstar--font-lock-ensure)
    (buffer-string)))

(defun fstar--highlight-docstring-region (beg end)
  "Highlight BEG..END as an F* docstring."
  (let ((inhibit-read-only t))
    (goto-char beg)
    (while (search-forward "[" end t)
      (let* ((beg (point))
             (end (ignore-errors (backward-char) (forward-sexp) (1- (point))))
             (str (and end (buffer-substring-no-properties beg end))))
        (if (null str)
            (goto-char end)
          (goto-char beg)
          (delete-region beg end)
          (insert (fstar-highlight-string str)))))))

(defun fstar--highlight-docstring (str)
  "Highlight STR as an F* docstring."
  (with-temp-buffer
    (insert str)
    (fstar--highlight-docstring-region (point-min) (point-max))
    (buffer-string)))

(make-variable-buffer-local 'font-lock-extra-managed-props)

(defun fstar-setup-font-lock ()
  "Setup font-lock for use with F*."
  (font-lock-mode -1)
  (setq-local
   font-lock-defaults
   `(((,fstar-syntax-constants-re    . 'font-lock-constant-face)
      (,fstar-syntax-keywords-re     . 'font-lock-keyword-face)
      (,fstar-syntax-builtins-re     . 'font-lock-builtin-face)
      (,fstar-syntax-preprocessor-re . 'font-lock-preprocessor-face)
      (,fstar-syntax-structure-re    . 'fstar-structure-face)
      ,@fstar-syntax-additional)
     nil nil))
  (font-lock-set-defaults)
  (add-to-list 'font-lock-extra-managed-props 'display)
  (add-to-list 'font-lock-extra-managed-props 'invisible)
  (add-to-list 'font-lock-extra-managed-props 'wrap-prefix)
  (add-to-list 'font-lock-extra-managed-props 'modification-hooks)
  (font-lock-mode))

(defun fstar-teardown-font-lock ()
  "Disable F*-related font-locking."
  (when (buffer-live-p fstar--scratchpad)
    (kill-buffer fstar--scratchpad)))

;;; Subscripts

(defconst fstar-subscripts--font-lock-spec
  `(,(fstar--fl-conditional-matcher fstar-syntax-id-with-subscript-re #'fstar--in-code-p)
    (1 '(face fstar-subscript-face display (raise -0.3)) append)))

(defun fstar-setup-subscripts ()
  "Setup pretty subscripts."
  (font-lock-add-keywords nil (list fstar-subscripts--font-lock-spec) 'append))

(defun fstar-teardown-subscripts ()
  "Teardown pretty subscripts."
  (font-lock-remove-keywords nil (list fstar-subscripts--font-lock-spec)))

;;; Syntax table

(defvar fstar-syntax-table
  (let ((table (make-syntax-table)))
    ;; Symbols
    (modify-syntax-entry ?# "_" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?' "_" table)
    ;; Punctuation
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?% "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?& "." table)
    (modify-syntax-entry ?| "." table)
    ;; Comments and strings
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\" "\"" table)
    ;; ‘/’ is handled by a `syntax-propertize-function'.  For background on this
    ;; see http://lists.gnu.org/archive/html/emacs-devel/2017-01/msg00144.html.
    ;; The comment enders are left here, since they don't match the ‘(*’ openers.
    ;; (modify-syntax-entry ?/ ". 12c" table)
    (modify-syntax-entry ?\n  ">" table)
    (modify-syntax-entry ?\^m ">" table)
    (modify-syntax-entry ?\( "()1nb" table)
    (modify-syntax-entry ?*  ". 23b" table)
    (modify-syntax-entry ?\) ")(4nb" table)
    table)
  "Syntax table for F*.")

(defconst fstar--fqn-at-point-syntax-table
  (let ((tbl (make-syntax-table fstar-syntax-table)))
    (modify-syntax-entry ?. "_" tbl)
    tbl))

(defconst fstar-mode-syntax-propertize-function
  (let ((opener-1 (string-to-syntax ". 1"))
        (opener-2 (string-to-syntax ". 2")))
    (syntax-propertize-rules
     ("//" (0 (let* ((pt (match-beginning 0))
                     (state (fstar--syntax-ppss pt)))
                ;; 3: string; 4: comment
                (unless (or (nth 3 state) (nth 4 state))
                  (put-text-property pt (+ pt 1) 'syntax-table opener-1)
                  (put-text-property (+ pt 1) (+ pt 2) 'syntax-table opener-2)
                  (ignore (goto-char (point-at-eol))))))))))

;;; Comment syntax

(defcustom fstar-comment-style 'line
  "Style applied to new comments: (* … *) or // ….
Consider customizing `comment-style', too."
  :type '(choice (const :tag "// Line comments" line)
                 (const :tag "(* Block comments *)" block))
  :set (lambda (symbol value)
         (set-default symbol value)
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (derived-mode-p 'fstar-mode)
               (fstar--set-comment-style)))))
  :group 'fstar)

;;;###autoload
(put 'fstar-comment-style 'safe-local-variable #'symbolp)

(defun fstar-syntactic-face-function (args)
  "Choose face to display based on ARGS."
  (pcase-let ((`(_ _ _ ,in-string _ _ _ _ ,comment-start-pos _) args))
    (cond (in-string ;; Strings
           font-lock-string-face)
          (comment-start-pos ;; Comments ('//' doesnt have a comment-depth
           (save-excursion
             (goto-char comment-start-pos)
             (cond
              ((looking-at-p fstar--literate-comment-re)
               'fstar-literate-comment-face)
              ((looking-at-p "([*]\\([*][*]\\|[*] ?[*]\\)[[:space:]\n]")
               '(:inherit font-lock-doc-face :height 2.5))
              ((looking-at-p "([*]\\([*]?[+]\\|[*] ?[*][*]\\)[[:space:]\n]")
               '(:inherit font-lock-doc-face :height 1.8))
              ((looking-at-p "([*]\\([*]?[!]\\|[*] ?[*][*][*]\\)[[:space:]\n]")
               '(:inherit font-lock-doc-face :height 1.5))
              ((looking-at-p "([*][*][^)]") 'font-lock-doc-face)
              (t 'font-lock-comment-face)))))))

(defun fstar--fix-fill-comment-paragraph (fcp &rest args)
  "Call FCP with ARGS unless point is in a ‘(*’ comment.
In non-fstar-mode buffers, call FCP unconditionally."
  ;; `fill-paragraph-handle-comment' is broken: it compares `comment-end' to ""
  ;; to check whether it should enable itself (it only works for single-line
  ;; comments), but then it forgets to confirm that the current comment starts
  ;; with `comment-start' and ends up incorrectly filling (* … *) comments.
  (unless (and (derived-mode-p 'fstar-mode)
               ;; (nth 7 …) is the comment style: 1 for ‘(*’ and nil for ‘//’
               (nth 7 (fstar--syntax-ppss)))
    (apply fcp args)))

(defun fstar--set-comment-style ()
  "Set comment delimiters based on `fstar-comment-style'."
  (pcase fstar-comment-style
    (`line
     (setq-local comment-start "// ")
     (setq-local comment-continue "// ")
     (setq-local comment-end ""))
    (_
     (setq-local comment-start "(* ")
     (setq-local comment-continue " * ")
     (setq-local comment-end " *)"))))

(defun fstar-setup-comments ()
  "Set comment-related variables for F*."
  (fstar--set-comment-style)
  (setq-local comment-multi-line t)
  (setq-local comment-use-syntax t)
  (setq-local fill-paragraph-handle-comment t)
  (setq-local comment-start-skip fstar-comment-start-skip)
  (let ((prefix "[ \t]*\\(//+\\|\\**\\)[ \t]*")
        (default-re (or (default-value 'adaptive-fill-regexp) "")))
    (setq-local adaptive-fill-regexp (format "%s\\(%s\\)" prefix default-re))
    (setq-local adaptive-fill-first-line-regexp (format "\\`%s\\'" prefix)))
  (setq-local font-lock-syntactic-face-function #'fstar-syntactic-face-function)
  (setq-local syntax-propertize-function fstar-mode-syntax-propertize-function)
  (when (fboundp 'advice-add)
    (advice-add #'fill-comment-paragraph :around #'fstar--fix-fill-comment-paragraph)))

(defun fstar-teardown-comments ()
  "Undo F*'s comment setup."
  (when (fboundp 'advice-remove)
    (advice-remove 'fill-comment-paragraph #'fstar--fix-fill-comment-paragraph)))

;;; Keymaps

(define-prefix-command 'fstar-query-map)
(define-key 'fstar-query-map (kbd "C-o") #'fstar-outline)
(define-key 'fstar-query-map (kbd "C-c") #'fstar-insert-match-dwim)
(define-key 'fstar-query-map (kbd "C-e") #'fstar-eval)
(define-key 'fstar-query-map (kbd "C-S-e") #'fstar-eval-custom)
(define-key 'fstar-query-map (kbd "C-s") #'fstar-search)
(define-key 'fstar-query-map (kbd "C-d") #'fstar-doc)
(define-key 'fstar-query-map (kbd "C-p") #'fstar-print)
(define-key 'fstar-query-map (kbd "C-q") #'fstar-quit-windows)
(define-key 'fstar-query-map (kbd "C-j C-d") #'fstar-visit-dependency)
(define-key 'fstar-query-map (kbd "h w") #'fstar-browse-wiki)
(define-key 'fstar-query-map (kbd "h W") #'fstar-browse-wiki-in-browser)
(define-key 'fstar-query-map (kbd "h o") #'fstar-list-options)

(defvar fstar-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Basics
    (define-key map (kbd "RET") #'fstar-newline)
    (define-key map (kbd "C-c C-v") #'fstar-cli-verify)
    ;; Navigation
    (define-key map (kbd "M-p") 'fstar-subp-previous-block-start)
    (define-key map (kbd "M-n") 'fstar-subp-next-block-start)
    (define-key map (kbd "M-.") #'fstar-jump-to-definition)
    (define-key map (kbd "C-x 4 .") #'fstar-jump-to-definition-other-window)
    (define-key map (kbd "C-x 5 .") #'fstar-jump-to-definition-other-frame)
    (define-key map (kbd "C-c C-'") #'fstar-jump-to-related-error)
    (define-key map (kbd "C-x 4 '") #'fstar-jump-to-related-error-other-window)
    (define-key map (kbd "C-x 5 '") #'fstar-jump-to-related-error-other-frame)
    (define-key map (kbd "C-c C-a") #'fstar-visit-interface-or-implementation)
    (define-key map (kbd "C-c C-S-a") #'fstar-literate-fst2rst)
    ;; Completion
    (define-key map (kbd "C-RET") #'company-manual-begin)
    (define-key map (kbd "<C-return>") #'company-manual-begin)
    ;; Indentation
    (define-key map (kbd "<backtab>") #'fstar-unindent-for-tab-command)
    (define-key map (kbd "S-TAB") #'fstar-unindent-for-tab-command)
    ;; Help at point
    (define-key map (kbd "C-h .") #'display-local-help) ;; For Emacs < 25
    (define-key map (kbd "C-h M-w") #'fstar-copy-help-at-point)
    (define-key map (kbd "<menu>") #'fstar-quick-peek)
    (define-key map (kbd "M-<f12>") #'fstar-quick-peek)
    ;; Queries
    (define-key map (kbd "C-c C-s") 'fstar-query-map)
    map))

(defun fstar-newline-and-indent (arg)
  "Call (newline ARG), and indent resulting line as the previous one."
  (interactive "*P")
  (if (save-excursion (beginning-of-line) (looking-at-p "[ \t]*$"))
      (progn (delete-region (point-at-bol) (point-at-eol))
             (newline arg)) ;; 24.3 doesn't support second argument
    (let ((indentation (current-indentation)))
      (newline arg)
      (indent-line-to indentation))))

(put 'fstar-newline-and-indent 'delete-selection t)

(defvar fstar-newline-hook '(fstar-newline-and-indent)
  "Hook called to insert a newline.")

(defun fstar-newline (arg)
  "Run functions in `fstar-newline-hook' with ARG until success."
  (interactive "*P")
  (run-hook-with-args-until-success 'fstar-newline-hook arg))
(put 'fstar-newline 'delete-selection t)

(defun fstar-copy-help-at-point ()
  "Copy contents of help-echo at point."
  (interactive)
  (-if-let* ((help (help-at-pt-string)))
      (kill-new help)
    (user-error "No error message here")))

(defun fstar--check-help-at-point ()
  "Check if help is available at point."
  (car (get-char-property-and-overlay (point) 'help-echo)))

;;; Indentation

(defun fstar--indentation-previous-line ()
  "Go to previous non-blank line."
  (goto-char (point-at-bol))
  (skip-chars-backward fstar--spaces))

(defun fstar--indentation-points-before (&optional max-column)
  "Add indentation points before MAX-COLUMN or current point to POINTS."
  (let ((points nil)
        (bol (point-at-bol)))
    (when max-column
      (move-to-column max-column))
    (while (> (point) bol)
      (skip-chars-backward " \t" bol)
      (when (/= (skip-chars-backward "^ \t" bol) 0)
        (push (current-column) points)))
    points))

(defun fstar--indentation-points ()
  "Collect indentation points for current line."
  (fstar--prog-widened-excursion
    (let ((points nil)
          (started-in-multiline-comment (fstar-in-comment-p (point-at-bol))))
      (while (and (not (bobp)) (> (or (car points) 1) 0))
        (fstar--indentation-previous-line)
        (let ((line-points (fstar--indentation-points-before (car points))))
          (when started-in-multiline-comment
            (setq line-points (-filter #'fstar--column-in-commment-p line-points)))
          (when (and (null points) line-points)
            (cl-pushnew (+ (car line-points) 2) (cdr line-points)))
          (setq points (nconc line-points points))))
      points)))

(defun fstar--indentation-insert-points ()
  "Show indentation points on current line."
  (beginning-of-line)
  (dolist (point (fstar--indentation-points))
    (move-to-column point t)
    (insert "^")))

(defun fstar--indent-1 (backwards)
  "Cycle (forwards or BACKWARDS) between relevant indentation points."
  (unless (fstar-in-literate-comment-p)
    (let* ((current-ind (current-indentation))
           (points (fstar--indentation-points))
           (pred (apply-partially (if backwards #'> #'<) current-ind))
           (remaining (or (-filter pred points) points))
           (target (car (if backwards (last remaining) remaining))))
      (when target
        (if (> (current-column) current-ind)
            (save-excursion (indent-line-to target))
          (indent-line-to target))))))

(defun fstar-indent ()
  "Cycle forwards between vaguely relevant indentation points."
  (interactive)
  (fstar--indent-1 nil))

(defun fstar-unindent ()
  "Cycle backwards between vaguely relevant indentation points."
  (interactive)
  (fstar--indent-1 t))

(defun fstar-unindent-for-tab-command ()
  "Like `indent-for-tab-command', but backwards."
  (interactive)
  (let ((tab-always-indent t)
        (indent-line-function #'fstar-unindent))
    (indent-for-tab-command)))

(defun fstar-setup-indentation ()
  "Setup indentation for F*."
  (setq-local indent-tabs-mode nil)
  (setq-local indent-line-function #'fstar-indent)
  (when (boundp 'electric-indent-inhibit) ; Emacs ≥ 24.4
    (setq-local electric-indent-inhibit t)))

(defun fstar-teardown-indentation ()
  "Remove indentation support for F*."
  (kill-local-variable 'indent-tabs-mode)
  (kill-local-variable 'electric-indent-inhibit)
  (kill-local-variable 'indent-line-function))

;;; Switching between interface and implementation

(defconst fstar--interface-implementation-ext-alist
  '(("fst" . "fsti") ("fsti" . "fst") ("fs" . "fsi") ("fsi" . "fs")))

(defun fstar-visit-interface-or-implementation ()
  "Switch between interface and implementation."
  (interactive)
  (unless buffer-file-name
    (user-error "Save this file before switching"))
  (when (string-match "\\`\\(.*\\)\\.\\(fst?i?\\)\\'" buffer-file-name)
    (let* ((ext (file-name-extension buffer-file-name))
           (fname (file-name-sans-extension buffer-file-name))
           (other-ext (cdr (assoc ext fstar--interface-implementation-ext-alist))))
      (let ((auto-mode-alist '(("" . fstar-mode))))
        (find-file (concat fname "." (or other-ext ext)))))))

(defalias 'fstar--visit-interface #'fstar-visit-interface-or-implementation)
(defalias 'fstar--visit-implementation #'fstar-visit-interface-or-implementation)

(defun fstar--visiting-interface-p ()
  "Check whether current buffer is an interface file."
  (and buffer-file-name
       (string-match-p "\\.fsti\\'" buffer-file-name)))

;;; Wiki

(defconst fstar--wiki-directory
  (expand-file-name "wiki" fstar--directory))

(defconst fstar--wiki-url
  "https://github.com/FStarLang/FStar.wiki.git")

(defun fstar-wiki--run-git-command (reason progress-msg error-fmt &rest args)
  "Run git with ARGS.
REASON is used in error messages if Git isn't available.
Progress is indicated with PROGRESS-MSG.  If git fails, print
ERROR-FMT with error message."
  (message "%s…" progress-msg)
  (fstar-find-executable "git" (format "Git (needed to %s)" reason))
  (with-temp-buffer
    (unless (eq 0 (apply #'process-file "git" nil (current-buffer) nil args))
      (error error-fmt (fstar--string-trim (buffer-string)))))
  (message "%s… done." progress-msg))

(defun fstar-wiki-init (&optional force)
  "Download F*'s wiki to /wiki.
No-op if the directory already exists and FORCE is nil.
Return non-nil if a new clone was made."
  (interactive "P")
  (unless (and (file-directory-p fstar--wiki-directory) (not force))
    (delete-directory fstar--wiki-directory t)
    (fstar-wiki--run-git-command
     "fetch F*'s wiki"
     (format "Fetching F*'s wiki from %s" fstar--wiki-url)
     (format "Could not clone %s to %s: “%%s”" fstar--wiki-url fstar--wiki-directory)
     "clone" "--depth" "1" fstar--wiki-url fstar--wiki-directory)
    t))

(defun fstar-wiki-refresh (&optional force)
  "Refresh clone of F*'s wiki.
With FORCE, make a fresh clone."
  (interactive)
  (unless (fstar-wiki-init force)
    (let ((label "refresh F*'s wiki")
          (default-directory fstar--wiki-directory))
      (fstar-wiki--run-git-command label
                              (format "Fetching F*'s wiki from %s" fstar--wiki-url)
                              (format "Could not fetch %s: “%%s”" fstar--wiki-url)
                              "fetch" "origin" "master")
      (fstar-wiki--run-git-command label
                              "Resetting F*'s wiki to latest HEAD"
                              "Could not reset wiki: “%s”"
                              "reset" "--hard" "FETCH_HEAD")
      (fstar-wiki--run-git-command label
                              "Cleaning up orphaned wiki files"
                              "Could not clean up wiki: “%s”"
                              "clean" "-df"))))

(defun fstar--wiki-titles ()
  "List available articles on the F* wiki."
  (unless (fstar-wiki-init)
    (with-demoted-errors "Error while updating the wiki: %s"
      (fstar-wiki-refresh)))
  (let ((names nil))
    (dolist (fname (directory-files fstar--wiki-directory))
      (when (string-match "\\`\\(.*\\)\\.md\\'" fname)
        (let* ((www-name (match-string 1 fname))
               (clean (replace-regexp-in-string "-" " " www-name t t)))
          (push (list clean fname www-name) names))))
    (nreverse names)))

(defun fstar-wiki--read-topic ()
  "Read an F* wiki topic interactively."
  (let* ((titles (fstar--wiki-titles))
         (topic (completing-read "Topic (TAB to show all): " titles nil t)))
    (or (assoc topic titles)
        (user-error "Unknown topic “%s”" topic))))

(defun fstar-browse-wiki (fname)
  "Visit FNAME in `fstar--wiki-directory'.
Interactively, offer titles of F* wiki pages."
  (interactive (list (nth 1 (fstar-wiki--read-topic))))
  (find-file (expand-file-name fname fstar--wiki-directory)))

(defun fstar-browse-wiki-in-browser (page-name)
  "Visit PAGE-NAME on F*'s wiki on Github."
  (interactive (list (nth 2 (fstar-wiki--read-topic))))
  (browse-url (format "https://github.com/FStarLang/FStar/wiki/%s" page-name)))

;;; Hiding windows

(defvar fstar--all-temp-buffer-names nil)

(defun fstar-quit-windows ()
  "Hide all temporary F* windows."
  (interactive)
  (mapc #'fstar--hide-buffer fstar--all-temp-buffer-names))

;;; Outline

(defun fstar--outline-close-and-goto (&optional _)
  "Close occur buffer and go to position at point."
  (interactive)
  (let ((pos (occur-mode-find-occurrence))
        (occur-buf (current-buffer)))
    (switch-to-buffer (marker-buffer pos))
    (goto-char pos)
    (kill-buffer occur-buf)))

(defun fstar--outline-cleanup (title)
  "Clean up outline buffer and give it a proper TITLE."
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (when (looking-at ".* matches for \\(?:\n\\|.\\)*? in buffer: .*?\n")
      (delete-region (point) (match-end 0)))
    (insert (fstar--propertize-title title) "\n")
    (when (fboundp 'font-lock--remove-face-from-text-property)
      (font-lock--remove-face-from-text-property (point) (point-max) 'face 'match))))

(defvar fstar--outline-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map occur-mode-map)
    (dolist (command '(occur-mode-goto-occurrence occur-mode-mouse-goto))
      (substitute-key-definition command #'fstar--outline-close-and-goto map))
    map))

(defun fstar-outline ()
  "Show an outline of the current buffer."
  (interactive)
  (let ((same-window-buffer-names '("*Occur*"))
        (outline-buffer-title (format "Outline of ‘%s’\n" (buffer-name)))
        (outline-buffer-name (format "*fstar-outline: %s*" (buffer-name))))
    (-when-let* ((buf (get-buffer outline-buffer-name)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (occur fstar-syntax-block-header-re)
    (when (buffer-live-p (get-buffer "*Occur*"))
      (with-current-buffer "*Occur*"
        (rename-buffer outline-buffer-name t)
        (toggle-truncate-lines t)
        (use-local-map fstar--outline-map)
        (fstar--outline-cleanup outline-buffer-title)))))

;;; Selective display

(defconst fstar-selective-display-markers '("\\(?:\n\\|^\\) *(\\*\\*).*$")
  "Regexps matching fragments to hide in HACL outline mode.")

(defconst fstar-selective-display-ellipsis " 👻"
  "Ellipsis replacing matches for `fstar-selective-display-markers'.")

(defface fstar-selective-display-face
  '((t :inherit font-lock-comment-face))
  "Face used to highlight `fstar-selective-display-ellipsis'."
  :group 'fstar)

(defun fstar-selective-display--hidden-text-at-1 (pos)
  "Return text hidden by selective display at POS."
  (when (get-text-property pos 'fstar-selective-display)
    (buffer-substring-no-properties
     (previous-single-property-change (1+ pos) 'fstar-selective-display)
     (next-single-property-change pos 'fstar-selective-display))))

(defun fstar-selective-display--hidden-text-at (pos)
  "Compute selective display help-echo at POS."
  (or (fstar-selective-display--hidden-text-at-1 pos)
      (fstar-selective-display--hidden-text-at-1 (1- pos))))

(defun fstar-selective-display--show-hidden-text (event)
  "Show hidden text from F*-mode's selective display at pos of EVENT."
  (interactive "e")
  (let ((window (posn-window (event-end event)))
        (pos (posn-point (event-end event))))
    (with-current-buffer (window-buffer window)
      (-when-let* ((hidden (fstar-selective-display--hidden-text-at pos)))
        (setq hidden (replace-regexp-in-string "^ *\n+" "" hidden nil t))
        (message "%s" (fstar-highlight-string hidden))))))

(defconst fstar-selective-display--ellipsis-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] 'fstar-selective-display--show-hidden-text)
    map))

(defconst fstar-selective-display--font-lock-face
  `(face fstar-selective-display-face
         fstar-selective-display t
         keymap ,fstar-selective-display--ellipsis-map
         display ,fstar-selective-display-ellipsis
         help-echo "Hidden; middle-click (mouse-2) to reveal.")
  "Font-lock facename for the current match.")

(defun fstar-selective-display--font-lock-spec-1 (regexp)
  "Compute a `font-lock-keywords' entry to hide REGEXP."
  `(,regexp 0 fstar-selective-display--font-lock-face prepend))

(defconst fstar-selective-display--font-lock-spec
  (mapcar #'fstar-selective-display--font-lock-spec-1 fstar-selective-display-markers))

(define-minor-mode fstar-selective-display-mode
  "Hide lines prefixed by `fstar-hacl-hide-marker'."
  :lighter " (**)"
  (cond
   (fstar-selective-display-mode
    (font-lock-add-keywords nil fstar-selective-display--font-lock-spec 'append)
    (add-to-list 'font-lock-extra-managed-props 'display)
    (add-to-list 'font-lock-extra-managed-props 'help-echo))
   (t
    (font-lock-remove-keywords nil fstar-selective-display--font-lock-spec)))
  (fstar--font-lock-ensure))

;;; Literate F*

(defconst fstar-literate--error-levels
  '(("debug" . info)
    ("info" . info)
    ("warning" . warning)
    ("error" . error)
    ("severe" . error)))

(defun fstar-literate--parse-errors (output checker buffer)
  "Parse literate F* errors in OUTPUT.
OUTPUT is the result of Flychecking BUFFER with CHECKER."
  (mapcar
   (lambda (js-error)
     (let-alist js-error
       (flycheck-error-new-at
        .line nil (cdr (assoc .level fstar-literate--error-levels)) .message
        :checker checker
        :filename .source
        :buffer buffer)))
   (flycheck-parse-json output)))

(defun fstar-literate--flycheck-verify-enabled ()
  "Create a verification result announcing whether fstar-literate is enabled."
  (let ((enabled (memq 'literate-flycheck fstar-enabled-modules)))
    (list
     (flycheck-verification-result-new
      :label "Checker selection"
      :message (if enabled "OK, checker enabled."
                 "Enable the ‘literate-flycheck’ \
module in fstar-enabled-modules to use this checker.")
      :face (if enabled 'success '(bold error))))))

(flycheck-define-command-checker 'fstar-literate
  "Flycheck checker for literate F*."
  :command '("python"
             (eval (expand-file-name "etc/fslit/lint.py" fstar--directory))
             "--stdin-filename" source-original
             "--dialect"
             (eval (cond ((derived-mode-p 'fstar-mode) "fst-rst")
                         ((derived-mode-p 'rst-mode) "rst")
                         (t (error "Unrecognized mode %S" major-mode))))
             "-")
  :standard-input t
  :error-parser #'fstar-literate--parse-errors
  :enabled (lambda () (or (not (fboundp 'flycheck-python-find-module))
                     (flycheck-python-find-module 'fstar-literate "docutils")))
  :predicate (lambda () (memq 'literate-flycheck fstar-enabled-modules))
  :verify (lambda (_checker)
            (append (fstar-literate--flycheck-verify-enabled)
                    (when (fboundp 'flycheck-python-verify-module)
                      (flycheck-python-verify-module 'fstar-literate "docutils"))))
  :modes '(fstar-mode fstar-literate--rst-mode))

(add-to-list 'flycheck-checkers 'fstar-literate)
(cl-pushnew 'fstar-literate--rst-mode (flycheck-checker-get 'rst-sphinx 'modes))

(defconst fstar-literate--point-marker
  "<<<'P'O'I'N'T'>>>")

(defun fstar-literate--run-converter (&rest args)
  "Run converter with ARGS on current buffer.
Return converted contents and adjusted value of point."
  (let* ((python (fstar-find-executable fstar-python-executable "Python"
                                   'fstar-python-executable 'local-only))
         (converter (expand-file-name "etc/fslit/translate.py" fstar--directory))
         (input (concat (buffer-substring-no-properties (point-min) (point))
                        fstar-literate--point-marker
                        (buffer-substring-no-properties (point) (point-max)))))
    (pcase-let* ((`(,exit-code . ,output)
                  (with-temp-buffer
                    (cons (apply #'call-process-region input nil python
                                 nil (current-buffer) nil converter
                                 "--marker" fstar-literate--point-marker args)
                          (buffer-string)))))
      (unless (eq exit-code 0)
        (error "Conversion error (%s):\n%s" exit-code output))
      (fstar-assert (string-match fstar-literate--point-marker output))
      (cons (concat (substring-no-properties output 0 (match-beginning 0))
                    (substring-no-properties output (match-end 0)))
            (1+ (match-beginning 0))))))

(defun fstar-literate--toggle (flag new-mode)
  "Run converter with FLAG, fill buffer with output, and run NEW-MODE."
  (pcase-let* ((modified (buffer-modified-p))
               (`(,rst . ,point)
                (fstar--widened-excursion (fstar-literate--run-converter flag))))
    (setq buffer-read-only nil)
    (fstar--widened-excursion
      (erase-buffer)
      (insert rst))
    (goto-char point)
    (push `(apply ,major-mode) buffer-undo-list)
    (funcall new-mode)
    (set-buffer-modified-p modified)))

(defun fstar-literate--rst-save ()
  "Translate RST back to F* and save result.
Current document must have a file name."
  (let ((source (current-buffer)))
    (with-temp-buffer
      (insert-buffer-substring source)
      (fstar-literate--toggle "--rst2fst" #'ignore)
      (write-region (point-min) (point-max) (buffer-file-name source))))
  (set-buffer-modified-p nil)
  (set-visited-file-modtime)
  t)

(defvar fstar-literate--rst-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-S-a") #'fstar-literate-rst2fst)
    map))

(define-derived-mode fstar-literate--rst-mode rst-mode "F✪-reStructuredText"
  "Mode for RST buffers backed by an F* file.
Press \\<fstar-literate--rst-mode-map>\\[fstar-literate-rst2fst] to
toggle between reStructuredText and F*."
  (flycheck-mode)
  (add-hook 'write-contents-functions #'fstar-literate--rst-save t t))

(defun fstar-literate-fst2rst ()
  "Toggle between F* and reStructuredText."
  (interactive)
  (fstar-subp-kill)
  (fstar-literate--toggle "--fst2rst" #'fstar-literate--rst-mode)
  (message (substitute-command-keys "Switched to reStructuredText mode.  \
Press \\[fstar-literate-rst2fst] to go back.")))

(defun fstar-literate-rst2fst ()
  "Toggle between reStructuredText and F*."
  (interactive)
  (fstar-literate--toggle "--rst2fst" #'fstar-mode)
  (message (substitute-command-keys "Switched to F* mode.  \
Press \\[fstar-literate-fst2rst] to go back.")))

(defun fstar-literate--marker-modification-hook (from to)
  "Handle backspace on literate comment marker.
FROM, TO: see `modification-hooks' text property."
  ;; backspace on “/// <|>” (but not at eol) or “///<|>”
  (when (and (eq (point) to)
             (eq (1- (point)) from)
             (or (eq (point) (+ 3 (point-at-bol)))
                 (and (eq (point) (+ 4 (point-at-bol)))
                      (not (eq (point) (point-at-eol))))))
    (let ((inhibit-modification-hooks t))
      (delete-region (point-at-bol) from))))

;; This was useful when using the fringe to highlight literate comments, since
;; there is no fringe on TTYs.
;; (defface fstar-literate-tty-gutter-face
;;   '((((type tty)) :inherit fstar-literate-gutter-face))
;;   "Face used for the gutter next to literate comments (///) on TTYs."
;;   :group 'fstar-literate)

(defconst fstar-literate--gutter-font-lock-props
  '(face fstar-literate-gutter-face display (space :width (+ (0) 0.5))))

(defconst fstar-literate--gutter-space-font-lock-props
  '(face nil display (space :width (+ 0.5 (0))))) ;; (+ … (0)) is for TTYs

(defconst fstar-literate--wrap-prefix
  (concat (apply #'propertize "///" fstar-literate--gutter-font-lock-props)
          (apply #'propertize " " fstar-literate--gutter-space-font-lock-props)))

(defconst fstar-literate--font-lock-keywords
  `(;; ("^\\(/\\)\\(//\\)\\( \\|$\\)"
    ;;  ;; Split /// because applying `left-fringe' + `space' to all of it gives
    ;;  ;; it a red highlight on otherwise empty lines.  Use `invisible' over
    ;;  ;; `cursor-intangible' because the latter is broken wrt deletion.
    ;;  (1 '(face fstar-literate-tty-gutter-face display (space :width (1))) prepend)
    ;;  (2 '(face nil invisible t display [(left-fringe fstar-literate-gutter-bitmap nil)]))
    ;;  (3 '(face nil display (space :width (+ 0.5 (1))))))
    ("^\\(\\(///\\)\\( \\|$\\)\\)\\(.*\\)"
     (1 '(face nil modification-hooks (fstar-literate--marker-modification-hook)))
     (2 fstar-literate--gutter-font-lock-props prepend)
     (3 fstar-literate--gutter-space-font-lock-props)
     (4 '(face nil wrap-prefix ,fstar-literate--wrap-prefix))))
  "Font-lock rules to highlight literate comments.
The original rule (see source code comments) used the fringe, but
it created a bunch of issues with point motion and deletion.")

(defun fstar-literate-newline (&optional _)
  "Like `comment-indent-new-line', but only in literate comments."
  (when (fstar-in-literate-comment-p)
    (let* ((comment-insert-comment-function (lambda () (insert "/// "))))
      (comment-indent-new-line)
      t)))

(defun fstar-literate-preview ()
  "Display an HTML preview of the current buffer."
  (interactive)
  (let* ((prefix (concat "fslit_" (buffer-name)))
         (html-fname (make-temp-file prefix nil ".html"))
         (fst2html (expand-file-name "etc/fslit/fst2html.py" fstar--directory))
         (contents (buffer-substring-no-properties (point-min) (point-max)))
         (python (fstar-find-executable fstar-python-executable "Python"
                                   'fstar-python-executable 'local-only)))
    (with-temp-buffer
      (pcase (call-process-region contents nil python
                                  nil t nil fst2html "-" html-fname)
        (`0 (message "Compilation complete: %s" (fstar--string-trim (buffer-string)))
            (browse-url html-fname))
        (err (error "Compilation failed: %s\n%s" err (buffer-string)))))))

(defun fstar-setup-literate ()
  "Set up literate comment highlighting."
  ;; (define-fringe-bitmap 'fstar-literate-gutter-bitmap [0])
  ;; (set-fringe-bitmap-face 'fstar-literate-gutter-bitmap 'fstar-literate-gutter-face)
  (visual-line-mode)
  (add-hook 'fstar-newline-hook #'fstar-literate-newline nil t)
  (font-lock-add-keywords nil fstar-literate--font-lock-keywords))

(defun fstar-teardown-literate ()
  "Tear down literate comment highlighting."
  (visual-line-mode -1)
  (remove-hook 'fstar-newline-hook #'fstar-literate-newline t)
  (font-lock-remove-keywords nil fstar-literate--font-lock-keywords))

;;; Auto-insert support

(defun fstar-auto-insert--infer-module-name ()
  "Guess name of current module from name of file or buffer."
  (replace-regexp-in-string
   "\\(?:^\\|[.]\\)[^.]" #'upcase
   (file-name-base (or (buffer-file-name) (buffer-name)))))

(defconst fstar-auto-insert--skeleton
  `(nil
    "(** " (read-string "Module description: ") | -1 "\n"
    "@summary " (read-string "Summary: ") | -1 "\n"
    ;; & "\n" | ,(- (length "@summary ")) ;; Must have @summary (GH-1216)
    "@author " (user-full-name) " <" (progn user-mail-address) ">" " **)\n"
    "module " (fstar-auto-insert--infer-module-name) "\n"))

(defconst fstar-auto-insert--alist-form
  `(("\\.fsti?\\'" . "F* program") . ,fstar-auto-insert--skeleton))

(defvar auto-insert-alist)

(defun fstar-setup-auto-insert ()
  "Register F* support for `auto-insert'."
  (setq-local auto-insert-alist (list fstar-auto-insert--alist-form)))

(defun fstar-teardown-auto-insert ()
  "Unregister F* support for `auto-insert'."
  (kill-local-variable 'auto-insert-alist))

;;; Interactive proofs (fstar-subp)

(cl-defstruct fstar-subp-query
  query args)

(defconst fstar-subp-legacy--success "ok")
(defconst fstar-subp-legacy--failure "nok")
(defconst fstar-subp-legacy--done "\n#done-")

(defconst fstar-subp-legacy--cancel "#pop")
(defconst fstar-subp-legacy--footer "\n#end #done-ok #done-nok")

(defconst fstar-subp-statuses '(pending busy processed))

(defvar-local fstar-subp--process nil
  "Interactive F* process running in the background.")

(defvar-local fstar-subp--prover-args nil
  "Arguments passed to the F* process running in the background.
The first argument is the name that the current file had when F*
was started.")

(defvar-local fstar-subp--continuations nil
  "Indicates which continuation to run on next output from F* subprocess.
This is a map from query ID to continuation.  In legacy mode, it
never contains more than one entry (with ID nil).")

(defvar-local fstar-subp--queue-timer nil)

(defvar fstar-subp--lax nil
  "Whether to process newly sent regions in lax mode.
A non-nil `fstar-subp-sloppy' overrides this value.")

(defcustom fstar-subp-sloppy nil
  "Whether to process all of the current buffer in lax mode.

Individual regions can be sent to F* in lax mode using
\\<fstar-mode-map>\\[fstar-subp-advance-or-retract-to-point-lax]."
  :group 'fstar-interactive
  :type 'boolean
  :safe 'booleanp)
(make-local-variable 'fstar-subp-sloppy)

(defface fstar-subp-overlay-lax-face
  '((t :slant italic :extend t))
  "Face used to highlight lax-checked sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-pending-face
  '((((background light)) :background "#AD7FA8" :extend t)
    (((background dark))  :background "#5C3566" :extend t))
  "Face used to highlight pending sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-pending-lax-face
  '((t :inherit (fstar-subp-overlay-pending-face fstar-subp-overlay-lax-face)))
  "Face used to highlight pending lax-checked sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-busy-face
  '((((background light)) :background "mistyrose" :extend t)
    (((background dark))  :background "mediumorchid" :extend t))
  "Face used to highlight busy sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-busy-lax-face
  '((t :inherit (fstar-subp-overlay-busy-face fstar-subp-overlay-lax-face)))
  "Face used to highlight busy lax-checked sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-processed-face
  '((((background light)) :background "#EAF8FF" :extend t)
    (((background dark))  :background "darkslateblue" :extend t))
  "Face used to highlight processed sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-processed-lax-face
  '((t :inherit (fstar-subp-overlay-processed-face fstar-subp-overlay-lax-face)))
  "Face used to highlight processed lax-checked sections of the buffer."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-error-face
  '((t :underline (:color "red" :style wave)))
  "Face used to highlight errors."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-warning-face
  '((t :underline (:color "orange" :style wave)))
  "Face used to highlight warnings."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-bullet-error-face
  '((t :foreground "red"))
  "Face used to color bullets indicating error locations."
  :group 'fstar-interactive)

(defface fstar-subp-overlay-bullet-warning-face
  '((t :foreground "orange"))
  "Face used to color bullets indicating warning locations."
  :group 'fstar-interactive)

(defmacro fstar-subp-with-process-buffer (proc &rest body)
  "If PROC is non-nil, move to PROC's buffer to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((procp    ,proc)
                (buf      (process-buffer ,proc))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

(defmacro fstar-subp-with-source-buffer (proc &rest body)
  "If PROC is non-nil, move to parent buffer of PROC to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((procp    ,proc)
                (buf      (process-get ,proc 'fstar-subp-source-buffer))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

(defvar gud-gdb-history)

(defun fstar-gdb ()
  "Attach GDB to this buffer's F* process.
See URL `https://askubuntu.com/questions/41629/` if you run into
ptrace-related issues."
  (interactive)
  (require 'gdb-mi)
  (unless (fstar-subp-live-p)
    (user-error "Start F* before attaching GDB"))
  (unless (executable-find "gdb")
    (user-error "Could not find a GDB binary in your exec-path"))
  (let* ((pid (process-id fstar-subp--process))
         (cmd (format "gdb -i=mi -p %d" pid))
         (gud-gdb-history (cons cmd (bound-and-true-p gud-gdb-history))))
    (call-interactively #'gdb)))

;;; ;; Overlay classification

(defun fstar-subp-issue-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp issue overlay."
  (overlay-get overlay 'fstar-subp-issue))

(defun fstar-subp-orphaned-issue-overlay-p (overlay)
  "Return non-nil if OVERLAY is an orphaned fstar-subp issue overlay."
  (and (overlay-get overlay 'fstar-subp-issue)
       (let ((parent (overlay-get overlay 'fstar-subp-issue-parent-overlay)))
         (or (null parent) (null (overlay-buffer parent))))))

(defun fstar-subp-issue-overlays (beg end)
  "Find all -subp issues overlays in BEG END."
  (-filter #'fstar-subp-issue-overlay-p (overlays-in beg end)))

(defun fstar-subp-issue-orphaned-overlays (beg end)
  "Find all -subp issues overlays in BEG END."
  (-filter #'fstar-subp-orphaned-issue-overlay-p (overlays-in beg end)))

(defun fstar-subp-issue-overlays-at (pt)
  "Find all -subp issues overlays at point PT."
  (-filter #'fstar-subp-issue-overlay-p (overlays-at pt)))

(defun fstar-subp-tracking-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp tracking overlay."
  (fstar-subp-status overlay))

(defun fstar-subp-tracking-overlays (&optional status pos)
  "Find all -subp tracking overlays with status STATUS at POS.

If STATUS is nil, return all fstar-subp overlays.  If POS is nil,
look in the entire buffer."
  (sort (cl-loop for overlay in (if pos (overlays-at pos)
                                  (overlays-in (point-min) (point-max)))
                 when (fstar-subp-tracking-overlay-p overlay)
                 when (or (not status) (fstar-subp-status-eq overlay status))
                 collect overlay)
        (lambda (o1 o2) (< (overlay-start o1) (overlay-start o2)))))

(defun fstar-subp--in-tracked-region-p ()
  "Check if point is in tracked region."
  (cl-some #'fstar-subp-tracking-overlay-p (overlays-at (point))))

(defun fstar-subp-remove-tracking-overlays ()
  "Remove all F* tracking overlays in the current buffer."
  (mapc #'delete-overlay (fstar-subp-tracking-overlays)))

(defun fstar-subp-remove-issue-overlays (beg end)
  "Remove all F* issue overlays in BEG .. END."
  (mapc #'delete-overlay (fstar-subp-issue-overlays beg end)))

(defun fstar-subp-remove-orphaned-issue-overlays (beg end)
  "Remove all F* issue overlays in BEG .. END whose overlay is dead."
  (mapc #'delete-overlay (fstar-subp-issue-orphaned-overlays beg end)))

;;; ;; Overlay status legend in modeline

(defconst fstar-subp--overlay-legend-mode-line
  (let ((sp (propertize " " 'display '(space :width 1.5)))
        (it (propertize " " 'display '(space :width 0.3))))
    `(,(propertize " " 'display '(space :align-to 0)) ;; 'face 'fringe
      ,(propertize "Legend: " 'face nil)
      ,(mapconcat
        (lambda (label-face)
          (propertize (concat "​" sp "​" (car label-face) "​" sp "​")
                      'face (cdr label-face)))
        `(("pending" . (fstar-subp-overlay-pending-face))
          ("busy" . (fstar-subp-overlay-busy-face))
          ("processed" . (fstar-subp-overlay-processed-face))
          (,(concat "lax-checked" it) . (fstar-subp-overlay-lax-face (:box -1))))
        "")
      " ")))

(defconst fstar-subp--overlay-legend-str
  (format-mode-line fstar-subp--overlay-legend-mode-line))

(defvar fstar-subp--overlay-legend-buffer nil
  "Buffer currently showing legend in modeline.")

(defun fstar-subp--hide-overlay-legend-mode-line ()
  "Hide legend of overlay statuses."
  (when (buffer-live-p fstar-subp--overlay-legend-buffer)
    (with-current-buffer fstar-subp--overlay-legend-buffer
      (setq fstar-subp--overlay-legend-buffer nil)
      (when (eq (car mode-line-format) fstar-subp--overlay-legend-mode-line)
        (pop mode-line-format)))))

(defun fstar-subp--show-overlay-legend-mode-line ()
  "Update modeline to contain legend of overlay statuses."
  (fstar-subp--hide-overlay-legend-mode-line)
  (setq fstar-subp--overlay-legend-buffer (current-buffer))
  (push fstar-subp--overlay-legend-mode-line mode-line-format))

(defun fstar-subp--overlay-legend-help-function (fn help-string)
  "Show legend of overlay statuses in buffer indicated by HELP-STRING.
If HELP-STRING doesn't have `fstar-subp--legend' property, call
FN instead."
  (-if-let* ((buf (and help-string
                       (get-text-property 0 'fstar-subp--legend help-string))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (fstar-subp--show-overlay-legend-mode-line)))
    (fstar-subp--hide-overlay-legend-mode-line)
    (funcall fn help-string)))

(defun fstar-setup-overlay-legend ()
  "Enable overlay legends in modeline."
  (tooltip-mode 1)
  ;; Must use advice, because tooltip mode aggressively resets
  ;; `show-help-function' to `tooltip-show-help'.
  (when (fboundp 'advice-add)
    (dolist (fn '(tooltip-show-help tooltip-show-help-non-mode))
      (advice-add fn :around #'fstar-subp--overlay-legend-help-function))))

(defun fstar-teardown-overlay-legend ()
  "Disable overlay legends in modeline."
  ;; No way to disable buffer-locally
  ;; (when (fboundp 'advice-remove)
  ;;   (dolist (fn '(tooltip-show-help tooltip-show-help-non-mode))
  ;;     (advice-remove fn #'fstar-subp--overlay-legend-help-function)))
  )

;;; ;; Basic subprocess operations

(defun fstar-subp-live-p (&optional proc)
  "Return t if the PROC is a live F* subprocess.
If PROC is nil, use the current buffer's `fstar-subp--process'."
  (setq proc (or proc fstar-subp--process))
  (and proc (process-live-p proc)))

(defun fstar-subp--busy-p ()
  "Return t if current `fstar-subp--process' is live and busy."
  (and (fstar-subp-live-p) (> (hash-table-count fstar-subp--continuations) 0)))

(defun fstar-subp-available-p ()
  "Return t if current `fstar-subp--process' is live and idle."
  (and (fstar-subp-live-p) (= (hash-table-count fstar-subp--continuations) 0)))

(defun fstar-subp--busy-with-overlays-p ()
  "Return t if current `fstar-subp--process' is live and busy with overlays."
  ;; LATER the performance of this part could be vastly improved by tracking
  ;; busy overlays separately, possibly by scanning the current continuation
  ;; table instead.  There are more places of the sort, though, which would
  ;; benefit from keeping a separate deque of overlays.
  (and (fstar-subp--busy-p) (fstar-subp-tracking-overlays 'busy)))

(defun fstar-subp--ensure-available (error-fn &optional feature)
  "Raise an error with ERROR-FN if F* isn't available.
Also raise an error if current subprocess doesn't meet version requirements for
FEATURE, if specified."
  (unless (fstar-subp-live-p)
    (funcall error-fn "Please start F* to use this feature"))
  (when (fstar-subp--busy-p)
    (funcall error-fn "F* seems busy; please wait until processing is complete"))
  (when feature
    (fstar--has-feature feature error-fn)))

(defun fstar-subp--find-any-live-process (error-fn)
  "Return a live fstar process if available in some buffer.
Raise an error with ERROR-FN if a live F* process isn't available anywhere."
  (or (cl-loop for buf in `(,(current-buffer) ,fstar--parent-buffer ,@(buffer-list))
               for proc = (and buf
                               (eq (buffer-local-value 'major-mode buf) 'fstar-mode)
                               (buffer-local-value 'fstar-subp--process buf))
               when (and proc (fstar-subp-live-p proc))
               return buf)
      (funcall error-fn "No F* process found.")))

(defun fstar-subp--serialize-query (query id)
  "Serialize QUERY with ID to JSON."
  (let ((json-encoding-pretty-print nil)
        (dummy-alist '(("dummy" . nil))))
    (json-encode `(("query-id" . ,id)
                   ("query" . ,(fstar-subp-query-query query))
                   ("args" . ,(or (fstar-subp-query-args query) dummy-alist))))))

(defun fstar-subp-continuations--put (id continuation)
  "Add CONTINUATION with ID in continuations table."
  (puthash id (make-fstar-continuation
               :id id :body continuation
               :start-time (current-time))
           fstar-subp--continuations))

(defvar-local fstar-subp--next-query-id 0)

(defun fstar-subp--query (query continuation)
  "Send QUERY to F* subprocess; handle results with CONTINUATION."
  (let ((id nil))
    (when (fstar-subp-query-p query)
      (setq id (number-to-string (cl-incf fstar-subp--next-query-id)))
      (setq query (fstar-subp--serialize-query query id)))
    (fstar-log 'in "%s" query)
    (if continuation
        (fstar-subp-continuations--put id continuation)
      (remhash id fstar-subp--continuations))
    (fstar-subp-start)
    (process-send-string fstar-subp--process (concat query "\n"))))

(defun fstar-subp--query-and-wait-1 (start query results-cell max-delay continuation)
  "Issues QUERY and wait for an answer for up to MAX-DELAY after START.
Results are passed to CONTINUATION, which should set (car
RESULTS-CELL) to t when invoked."
  (if (not (fstar-subp-available-p))
      (funcall continuation nil nil)
    ;; Issue query immediately, storing results in a shared reference.
    (fstar-subp--query query continuation)
    ;; Wait for a bit, hoping to get candidates quickly.  We need a loop,
    ;; because output may come in chunks.
    (while (and (not (car results-cell))
                (< (float-time (time-since start)) max-delay))
      (accept-process-output fstar-subp--process 0.005 nil 0))))

(defun fstar-subp--query-and-wait (query max-sync-delay)
  "Issue QUERY and try to return RESULTS synchronously.
Wait for MAX-SYNC-DELAY seconds at most.  If results were
received while waiting return a cons (t . (STATUS RESULTS)).
Otherwise, return a cons ('needs-callback . _).  In the latter
case, the caller should write a callback to the `cdr' of the
return value."
  (let* ((start (current-time))
         (results-cell (cons nil nil))
         (callback-cell (cons 'needs-callback nil)))
    ;; Issue query immediately and wait for a bit
    (fstar-subp--query-and-wait-1
     start query results-cell max-sync-delay
     (lambda (status results)
       (setf (car results-cell) t)
       (setf (cdr results-cell) (list status results))
       (when (cdr callback-cell)
         (apply (cdr callback-cell) (cdr results-cell)))))
    ;; Check for results
    (cond
     ((car results-cell) ;; Got results in time!
      (fstar-log 'info "[%.2fms] Fetched results for %S"
            (* 1000 (float-time (time-since start))) query)
      results-cell)
     (t ;; Results are late.  Set callback to company-supplied one.
      (fstar-log 'info "Results for %S are late" query)
      callback-cell))))

(defun fstar-subp-legacy--find-response (proc)
  "Find full response in PROC's legacy-mode buffer; handle it if found."
  (setq ansi-color-context-region nil)
  (ansi-color-filter-region (point-min) (point-max))
  (goto-char (point-min))
  (when (search-forward fstar-subp-legacy--done nil t)
    (let* ((status        (cond
                           ((looking-at fstar-subp-legacy--success) 'success)
                           ((looking-at fstar-subp-legacy--failure) 'failure)
                           (t 'unknown)))
           (resp-beg      (point-min))
           (resp-end      (point-at-bol))
           (resp-real-end (point-at-eol))
           (response      (fstar--string-trim (buffer-substring resp-beg resp-end))))
      (fstar-log 'info "Complete message received (status: %S)" status)
      (delete-region resp-beg resp-real-end)
      (when (fstar-subp-live-p proc)
        (fstar-subp-with-source-buffer proc
          (unless (memq status '(success failure))
            (fstar-subp-kill)
            (error "Unknown status [%s] from F* subprocess \
\(response was [%s])" status response))
          (fstar-subp--process-response nil status response))))))

(defun fstar-subp-json--parse-status (status response)
  "Convert STATUS to a symbol indicating success.
RESPONSE is used in warning messages printed upon failure."
  (pcase status
    ((or "success" "failure") (intern status))
    (_ (warn "Unknown status %S from F* subprocess \
\(response was [%S])" status response)
       `failure)))

(defun fstar-subp-json--read-response (beg end)
  "Read JSON message from BEG to END."
  (goto-char beg)
  (let* ((json-null :json-null)
         (json-false :json-false)
         (json-key-type 'symbol)
         (json-array-type 'list)
         (json-object-type 'alist)
         (json (when (eq (char-after) ?\{)
                 (condition-case nil (json-read)
                   (json-error nil)))))
    (cond
     ((null json)
      (ignore (fstar-log 'warning "%s" (buffer-substring beg end))
              (message "[F* raw output] %s" (buffer-substring beg end))))
     ((/= (point) end)
      (ignore (fstar-log 'warning "Junk follows JSON message: %s" (buffer-substring beg end))))
     (t
      (fstar-log 'info "Complete message received: (status: %S; message: %S)"
            (let-alist json .status) json)
      json))))

(defun fstar-subp-json--find-response (proc)
  "Find full response in PROC's json-mode buffer; handle it if found."
  (while (search-forward "\n" nil t)
    (let* ((js-end (1- (point)))
           (json (and (> js-end (point-min)) ;; Strip empty lines
                      (fstar-subp-json--read-response (point-min) js-end))))
      (goto-char (point-min))
      (delete-region (point-min) (1+ js-end))
      (when json
        (let-alist json
          (fstar-subp-with-source-buffer proc
            (pcase .kind
              ("message"
               (fstar-subp--process-message .level .contents))
              ("protocol-info"
               (when (fstar-subp-live-p proc)
                 (fstar-subp--process-protocol-info .version .features)))
              ("response"
               (let ((status (fstar-subp-json--parse-status .status .response)))
                 (when (fstar-subp-live-p proc)
                   (fstar-subp--process-response .query-id status .response))))))))))
  ;; Skip to end of partial response
  (goto-char (point-max)))

(defun fstar-subp-find-response (proc)
  "Find full response in PROC's buffer; handle it if found."
  (if (fstar--has-feature 'json-subp)
      (fstar-subp-json--find-response proc)
    (fstar-subp-legacy--find-response proc)))

(defvar fstar-subp--modeline-label ""
  "Label displayed next to F*'s logo in the modeline.")
(put 'fstar-subp--modeline-label 'risky-local-variable t)

(defun fstar-subp--display-progress (progress-info)
  "Update `fstar-subp--modeline-label' based on a PROGRESS-INFO."
  (setq fstar-subp--modeline-label
        (let-alist progress-info
          (pcase .stage
            ("loading-dependency"
             `(:propertize ,(format "{%s…}" .modname) face shadow))
            (_ ""))))
  (force-mode-line-update))

(defun fstar-subp--process-message (level contents)
  "Process CONTENTS of real-time feedback message at LEVEL."
  (pcase level
    ("proof-state" (fstar-tactics--display-proof-state contents))
    ("progress" (fstar-subp--display-progress contents))
    (_ (let ((header (pcase level
                       ("info" "[F*] ")
                       (_ (format "[F* %s] " level)))))
         (unless (stringp contents)
           (setq contents (prin1-to-string contents)))
         (message "%s" (fstar--indent-str (fstar--string-trim contents) header))))))

(defun fstar-subp--process-protocol-info (_vernum proto-features)
  "Register information (VERNUM and PROTO-FEATURES) about the protocol."
  (setq proto-features (mapcar #'intern proto-features))
  (setq fstar--features (append proto-features fstar--features))
  (fstar-subp-with-process-buffer fstar-subp--process
    (setq fstar--features (append proto-features fstar--features))))

(defun fstar-subp--process-response (id status response)
  "Process STATUS and RESPONSE for query ID from F* subprocess."
  (let* ((source-buffer (current-buffer))
         (continuation (gethash id fstar-subp--continuations)))
    (when (null continuation)
      (let ((conts (format "%S" fstar-subp--continuations)))
        (fstar-subp-kill)
        (error "Invalid state: Received orphan response %S to query %S.
Table of continuations was %s" response id conts)))
    (remhash id fstar-subp--continuations)
    (unwind-protect
        (fstar--widened
          (fstar-log 'info "Query %S completed in %.4fs" id
                (float-time (fstar-continuation--delay continuation)))
          (funcall (fstar-continuation-body continuation) status response))
      (with-current-buffer source-buffer
        (fstar-subp--set-queue-timer)))))

(defun fstar-subp-warn-unexpected-output (string)
  "Warn user about unexpected output STRING."
  (message "F*: received unexpected output from subprocess (%s)" string))

(defun fstar-subp-filter (proc string)
  "Handle PROC's output (STRING)."
  (when string
    (fstar-log 'out "%s" string)
    (let ((proc-buf (process-buffer proc)))
      (if (buffer-live-p proc-buf)
          (fstar-subp-with-process-buffer proc
            (save-excursion
              (goto-char (point-max))
              (insert string))
            (fstar-subp-find-response proc))
        (run-with-timer 0 nil #'fstar-subp-warn-unexpected-output string)))))

(defun fstar-subp-sentinel (proc signal)
  "Handle PROC's SIGNAL."
  (fstar-log 'info "Signal received: [%s] [%s]" signal (process-status proc))
  (when (or (memq (process-status proc) '(exit signal))
            (not (process-live-p proc)))
    (message "F*: subprocess exited.")
    (fstar-subp-with-source-buffer proc
      ;; This may be called after switching to RST
      (when (derived-mode-p 'fstar-mode)
        (fstar-subp-killed)))))

(defun fstar-subp--clear-continuations ()
  "Get rid of all pending continuations."
  (when fstar-subp--continuations
    (maphash (lambda (_ cont)
               (funcall (fstar-continuation-body cont) 'interrupted nil))
             fstar-subp--continuations)
    (clrhash fstar-subp--continuations)))

(defun fstar-subp-killed ()
  "Clean up current source buffer."
  (fstar-subp-with-process-buffer fstar-subp--process
    (let ((leftovers (fstar--string-trim (buffer-string))))
      (unless (equal leftovers "")
        (message "F* subprocess died early: %s" leftovers)))
    (kill-buffer))
  (fstar--widened
    (fstar-subp-remove-issue-overlays (point-min) (point-max))
    (fstar-subp-remove-tracking-overlays)
    (fstar-subp--clear-continuations)
    (flycheck-clear t)
    (setq fstar--vernum nil
          fstar--features nil
          fstar-subp--process nil
          fstar-subp--prover-args nil
          fstar-subp--queue-timer nil
          fstar-subp--next-query-id 0)))

(defun fstar-subp-kill ()
  "Kill F* subprocess and clean up current buffer.
This first sends EOF, and .25 seconds later sends a SIGTERM."
  (interactive)
  (when (fstar-subp-live-p) ;; Try to exit gently first…
    (process-send-eof fstar-subp--process)
    (accept-process-output fstar-subp--process 0.25 nil t))
  (when (fstar-subp-live-p) ;; …and then not so gently
    (kill-process fstar-subp--process)
    (accept-process-output fstar-subp--process 0.25 nil t))
  (fstar-subp-killed))

(defun fstar-subp-kill-all ()
  "Kill (send a SIGTERM to) F* subprocesses in all buffers."
  (interactive)
  (dolist (proc (process-list))
    (when (process-get proc 'fstar-subp-source-buffer)
      (kill-process proc))))

(defun fstar-subp-kill-one-or-many (&optional arg)
  "Kill current F* subprocess.
With prefix argument ARG, kill all F* subprocesses."
  (interactive "P")
  (if (consp arg)
      (fstar-subp-kill-all)
    (fstar-subp-kill)))

(defun fstar-subp-kill-proc (proc)
  "Same as `fstar-subp-kill', but for PROC instead of `fstar-subp--process'."
  (fstar-subp-with-source-buffer proc
    (when fstar-subp--process
      (fstar-assert (eq proc fstar-subp--process))
      (fstar-subp-kill))))

;;; ;; Killing Z3

;; FIXME get rid of the process enumeration code now that we can just simply
;; send a sigint to F*

(defconst fstar--ps-line-regexp
  "^ *\\([0-9]+\\) +\\([0-9]+\\) \\(.+\\) *$")

(defun fstar--ps-processes ()
  "Collect all running processes using `ps'.
Each return value is a list (PID PARENT-PID CMD)."
  (mapcar (lambda (line)
            (if (string-match fstar--ps-line-regexp line)
                (list (string-to-number (match-string 1 line))
                      (string-to-number (match-string 2 line))
                      (match-string 3 line))
              (error "Unexpected line in PS output: %S" line)))
          (cdr (process-lines "ps" "-axww" "-o" "pid,ppid,comm"))))

(defun fstar--elisp-process-attributes (pid)
  "Get attributes of process PID, or nil."
  (let* ((attrs (process-attributes pid)))
    (when attrs
      (list pid
            (cdr (assq 'ppid attrs))
            (cdr (assq 'comm attrs))))))

(defun fstar--elisp-processes ()
  "Collect all running processes using `system-processes'.
Each return value is a list (PID PPID CMD ARGS).  Return nil if
`list-system-processes' or `process-attributes' is unsupported."
  (delq nil (mapcar #'fstar--elisp-process-attributes (list-system-processes))))

(defun fstar--system-processes ()
  "Collect all running processes.
Each return value is a list (PID PPID CMD ARGS).  Uses
`list-processes' when available, and `ps' otherwise."
  (or (fstar--elisp-processes) (fstar--ps-processes)))

(defun fstar-subp-kill-z3 (all)
  "Kill Z3 subprocesses associated with the current F* process.
With non-nil ALL (interactively, with prefix argument), kill all
Z3 processes.  If F* isn't busy and ALL is nil this function
returns without doing anything."
  (interactive "P")
  (when (and (not all) (fstar-subp-available-p))
    (user-error "No busy F* process to interrupt"))
  (let ((parent-live (fstar-subp-live-p)))
    (unless (or all parent-live)
      (user-error "No F* process in this buffer"))
    (let ((subp-pid (and parent-live (process-id fstar-subp--process))))
      (pcase-dolist (`(,pid ,ppid ,cmd) (fstar--system-processes))
        (when (and (or all (eq ppid subp-pid))
                   (or (string-suffix-p "z3" cmd)
                       (string-suffix-p "z3.exe" cmd)))
          (signal-process pid 'int)
          (message "Sent SIGINT to %S (%S)" pid cmd))))))

(defun fstar-subp--interrupt-fstar ()
  "Interrupt the current F* computation."
  (when (or (not (fstar-subp-live-p)) (fstar-subp-available-p))
    (user-error "No busy F* process to interrupt"))
  (signal-process (process-id fstar-subp--process) 'int))

(defun fstar-subp-interrupt ()
  "Interrupt the current F* computation.
On older versions of F*, try to interrupt the underlying Z3
process — this is unreliable."
  (interactive)
  (if (fstar--has-feature 'interrupt)
      (fstar-subp--interrupt-fstar)
    (message "Consider upgrading to the latest F* to get reliable interrupts")
    (fstar-subp-kill-z3 nil)))

;;; ;; Parsing and display issues

(defun fstar-subp--pop ()
  "Issue a `pop' query.
Recall that the legacy F* protocol doesn't ack pops."
  (if (fstar--has-feature 'json-subp)
      (fstar-subp--query (make-fstar-subp-query :query "pop" :args nil) #'ignore)
    (fstar-subp--query fstar-subp-legacy--cancel nil)))

(defvar fstar-subp-overlay-processed-hook nil
  "Hook run after processing an overlay.
An overlay is “processed” once the corresponding verification
task has completed.  This hook is called with the same arguments
as `fstar-subp--overlay-continuation', after highlighting
potential errors.")

(defun fstar-subp--overlay-continuation (overlay status response)
  "Handle the results (STATUS and RESPONSE) of processing OVERLAY."
  (unless (eq status 'interrupted)
    (fstar-subp-parse-and-highlight-issues status response overlay)
    (if (eq status 'success)
        (fstar-subp-set-status overlay 'processed)
      (fstar-subp-remove-unprocessed)
      ;; Legacy protocol requires a pop after failed pushes
      (unless (fstar--has-feature 'json-subp)
        (fstar-subp--pop))))
  (run-hook-with-args 'fstar-subp-overlay-processed-hook overlay status response))

(cl-defstruct fstar-issue
  level locs message number)

(defun fstar-issue-alt-locs (issue)
  "Extract locations attached to ISSUE, except the first one."
  (cdr (fstar-issue-locs issue)))

(defun fstar-issue-message-with-level (issue)
  "Concatenate ISSUE's level and message."
  (format "(%s%s) %s"
          (capitalize (symbol-name (fstar-issue-level issue)))
          (-if-let* ((num (fstar-issue-number issue)))
             (concat " " (number-to-string num))
             "")
          (fstar-issue-message issue)))

(defconst fstar-subp-issue-location-regexp
  "\\(.*?\\)(\\([[:digit:]]+\\),\\([[:digit:]]+\\)-\\([[:digit:]]+\\),\\([[:digit:]]+\\))")

(defconst fstar-subp-legacy--issue-regexp
  (concat "^" fstar-subp-issue-location-regexp "\\s-*:\\s-*"))

(defconst fstar-subp--also-see-regexp
  (concat " *(\\(?:Also see:\\|see also\\) *" fstar-subp-issue-location-regexp ")"))

(defun fstar-subp-legacy--parse-issue (limit)
  "Construct an issue object from the current match data up to LIMIT."
  (pcase-let* ((issue-level 'error)
               (message (buffer-substring (match-end 0) limit))
               (`(,filename ,line-from ,col-from ,line-to ,col-to)
                (or (save-match-data
                      (when (string-match fstar-subp--also-see-regexp message)
                        (prog1 (fstar--match-strings-no-properties '(1 2 3 4 5) message)
                          (setq message (substring message 0 (match-beginning 0))))))
                    (fstar--match-strings-no-properties '(1 2 3 4 5)))))
    (pcase-dolist (`(,marker . ,level) '(("(Warning) " . warning)
                                         ("(Error) " . error)))
      (when (string-prefix-p marker message)
        (setq issue-level level)
        (setq message (substring message (length marker)))))
    (make-fstar-issue :level issue-level
                      :locs `(,(make-fstar-location
                                :filename filename
                                :line-from (string-to-number line-from)
                                :col-from (string-to-number col-from)
                                :line-to (string-to-number line-to)
                                :col-to (string-to-number col-to)))
                      :message message
                      :number nil)))

(defun fstar-subp-json--extract-alt-locs (message)
  "Extract secondary locations (see also, Also see) from MESSAGE.
Returns a pair of (CLEAN-MESSAGE . LOCATIONS)."
  (let ((locations nil))
    (while (string-match fstar-subp--also-see-regexp message)
      (pcase-let* ((`(,filename ,line-from ,col-from ,line-to ,col-to)
                    (fstar--match-strings-no-properties '(1 2 3 4 5) message)))
        (push (make-fstar-location
               :filename filename
               :line-from (string-to-number line-from)
               :line-to (string-to-number line-to)
               :col-from (string-to-number col-from)
               :col-to (string-to-number col-to))
              locations))
      (setq message (replace-match "" t t message)))
    (cons message locations)))

(defun fstar-subp-json--parse-location (json)
  "Convert JSON info an fstar-mode location."
  (let-alist json
    (make-fstar-location
     :filename (fstar-subp--fixup-fname .fname)
     :line-from (elt .beg 0)
     :line-to (elt .end 0)
     :col-from (elt .beg 1)
     :col-to (elt .end 1))))

(defun fstar-subp-json--parse-issue (json)
  "Convert JSON issue into fstar-mode issue."
  (let-alist json
    (pcase-let* ((`(,msg . ,alt-locs) (fstar-subp-json--extract-alt-locs .message)))
      (make-fstar-issue
       :level (intern .level)
       :locs (append (mapcar #'fstar-subp-json--parse-location .ranges) alt-locs)
       :message (fstar--string-trim msg)
       :number .number))))

(defun fstar-subp-parse-issues (response)
  "Parse RESPONSE into a list of issues."
  (cond
   ((fstar--has-feature 'json-subp)
    (mapcar #'fstar-subp-json--parse-issue response))
   ((stringp response)
    (unless (equal response "")
      (with-temp-buffer
        (insert response)
        (let ((bound (point-max)))
          (goto-char (point-max))
          ;; Matching backwards makes it easy to capture multi-line issues.
          (cl-loop while (re-search-backward fstar-subp-legacy--issue-regexp nil t)
                   collect (fstar-subp-legacy--parse-issue bound)
                   do (setq bound (match-beginning 0)))))))))

(defun fstar-subp--local-loc-p (loc)
  "Check if LOC came from the current buffer."
  (and loc (string= buffer-file-name (fstar-location-remote-filename loc))))

(defun fstar-subp--fixup-fname (fname)
  "Return FNAME, or the name of the current buffer if FNAME is <input>."
  (if (equal fname "<input>")
      (progn (fstar-assert buffer-file-name) buffer-file-name)
    fname))

(defun fstar-subp-cleanup-issue (issue &optional ov)
  "Fixup ISSUE: clean up file name and adjust line numbers wrt OV."
  (dolist (loc (fstar-issue-locs issue))
    ;; Adjust line numbers
    (unless (or (fstar--has-feature 'absolute-linums-in-errors) (null ov))
      (let ((linum (1- (line-number-at-pos (overlay-start ov)))))
        (cl-incf (fstar-location-line-from loc) linum)
        (cl-incf (fstar-location-line-to loc) linum))))
  ;; Put local ranges first
  (let ((partitioned (-group-by #'fstar-subp--local-loc-p (fstar-issue-locs issue))))
    (setf (fstar-issue-locs issue)
          (append (cdr (assq t partitioned))
                  (cdr (assq nil partitioned)))))
  issue)

(defun fstar-subp--issues-at (pt)
  "Get issues at PT or PT - 1, if any."
  (mapcar (lambda (ov) (overlay-get ov 'fstar-subp-issue))
          (cl-remove-duplicates
           (append (fstar-subp-issue-overlays-at pt)
                   (and (> pt (point-min))
                        (fstar-subp-issue-overlays-at (1- pt)))))))

(defun fstar-subp--in-issue-p (pt)
  "Check if PT is covered by an F* issue overlay."
  (or (get-char-property pt 'fstar-subp-issue)
      (and (> pt (point-min))
           (get-char-property (1- pt) 'fstar-subp-issue))))

(defun fstar-subp--alt-locs-at (pt)
  "Return a list of alternate locations at PT."
  (apply #'append (mapcar #'fstar-issue-alt-locs (fstar-subp--issues-at pt))))

(defun fstar-subp-remove-issue-overlay (overlay &rest _args)
  "Remove OVERLAY."
  (delete-overlay overlay))

(defconst fstar-subp--related-location-help-string-1
  (format "\\[fstar-jump-to-related-error] to visit, %s to come back"
          (if (fboundp 'xref-pop-marker-stack)
              "\\[xref-pop-marker-stack]" "\\[pop-global-mark]")))

(defun fstar-subp--related-location-help-string ()
  "Build a string describing motion commands for related locations."
  (substitute-command-keys fstar-subp--related-location-help-string-1))

(defun fstar-subp--help-echo-for-alt-locs (locs)
  "Prepare a string describing LOCS and how to browse to them."
  (if (null locs) ""
    (propertize
     (format
      (if (cdr locs) "\nRelated locations (%s):\n%s"
        "\nRelated location (%s): %s")
      (fstar-subp--related-location-help-string)
      (mapconcat #'fstar--loc-to-string locs "\n"))
     'face 'italic)))

(defun fstar-subp--help-echo-at (pos)
  "Compute help-echo message at POS."
  (-when-let* ((issues (fstar-subp--issues-at pos)))
    (concat (mapconcat #'fstar-issue-message-with-level issues "\n")
            (fstar-subp--help-echo-for-alt-locs (fstar-subp--alt-locs-at pos)))))

(defun fstar-subp--help-echo (_window object pos)
  "Concatenate -subp messages found at POS of OBJECT."
  (-when-let* ((buf (cond ((bufferp object) object)
                          ((overlayp object) (overlay-buffer object)))))
    (with-current-buffer buf
      (fstar-subp--help-echo-at pos))))

(defun fstar-subp-issue-face (issue)
  "Compute a face for ISSUE's overlay."
  (pcase (fstar-issue-level issue)
    (`error 'fstar-subp-overlay-error-face)
    (`warning 'fstar-subp-overlay-warning-face)))

(defun fstar-subp-issue-bullet-face (issue)
  "Compute a face for ISSUE's bullet point."
  (pcase (fstar-issue-level issue)
    (`error 'fstar-subp-overlay-bullet-error-face)
    (`warning 'fstar-subp-overlay-bullet-warning-face)))

(defconst fstar-subp--issue-bullet
  (let* ((spacer (propertize " " 'display '(space :width 0.5))))
    (concat spacer "⬩" spacer)))

(defun fstar-subp-highlight-issue (issue parent)
  "Highlight ISSUE in current buffer.
PARENT is the overlay whose processing caused this issue to be
reported."
  (-when-let* ((loc (car (fstar-issue-locs issue)))
               (from (fstar-location-beg-offset loc))
               (to (fstar-location-end-offset loc))
               (overlay (make-overlay from (max to (1+ from)) (current-buffer) t nil))
               ;; (bullet (propertize fstar-subp--issue-bullet 'face bullet-face))
               (bullet-face (fstar-subp-issue-bullet-face issue)))
    (overlay-put overlay 'fstar-subp-issue issue)
    (overlay-put overlay 'fstar-subp-issue-parent-overlay parent)
    (overlay-put overlay 'face (fstar-subp-issue-face issue))
    (overlay-put overlay 'priority 1) ;; Take precedence over ispell
    (overlay-put overlay 'help-echo #'fstar-subp--help-echo)
    ;; (overlay-put overlay 'before-string bullet)
    (dolist (hook '(modification-hooks
                    insert-in-front-hooks
                    insert-behind-hooks))
      (overlay-put overlay hook '(fstar-subp-remove-issue-overlay)))
    (when (fboundp 'pulse-momentary-highlight-region)
      (pulse-momentary-highlight-region from to))))

(defun fstar-subp-highlight-issues (issues parent)
  "Highlight ISSUES caused by processing of PARENT overlay."
  (mapc (lambda (i) (fstar-subp-highlight-issue i parent)) issues))

(defun fstar-subp-jump-to-issue (issue)
  "Jump to ISSUE in current buffer."
  (-when-let* ((loc (car (fstar-issue-locs issue))))
    (push-mark nil t)
    (goto-char (fstar-location-beg-offset loc))
    (display-local-help)))

(defun fstar-subp--local-issue-p (issue)
  "Check if any location in ISSUE came from the current buffer."
  ;; Local locations come first in list of locations
  (fstar-subp--local-loc-p (car (fstar-issue-locs issue))))

(defcustom fstar-jump-to-errors t
  "Whether to move the point to the first issue after processing a fragment."
  :group 'fstar-interactive
  :type '(choice (const :tag "Move to first error" t)
                 (const :tag "Move to first error or warning" errors-and-warnings)
                 (const :tag "Do not move" nil))
  :safe 'symbolp)

(defun fstar-subp--target-issue (issues)
  "Find an issue in ISSUES to jump to, based on `fstar-jump-to-errors'."
  (pcase fstar-jump-to-errors
    (`t (cl-find-if (lambda (i) (eq (fstar-issue-level i) 'error)) issues))
    (`errors-and-warnings (car issues))
    (`nil nil)))

(defun fstar-subp-parse-and-highlight-issues (status response overlay)
  "Parse issues in RESPONSE (caused by processing OVERLAY) and display them.
Complain if STATUS is `failure' and RESPONSE doesn't contain issues."
  (let* ((raw-issues (fstar-subp-parse-issues response))
         (issues (mapcar (lambda (i) (fstar-subp-cleanup-issue i overlay)) raw-issues))
         (partitioned (-group-by #'fstar-subp--local-issue-p issues))
         (local-issues (cdr (assq t partitioned)))
         (other-issues (cdr (assq nil partitioned))))
    (when (and (eq status 'failure) (null issues))
      (fstar-log 'info "No issues in response despite failure: [%s]" response))
    (when other-issues
      (message "F* reported issues in other files: [%S]" other-issues))
    (when issues
      (fstar-log 'info "Highlighting issues: %s" issues))
    (when local-issues
      (fstar-subp-highlight-issues local-issues overlay)
      (-if-let* ((target-issue (fstar-subp--target-issue local-issues)))
          (fstar-subp-jump-to-issue target-issue)
        (message "%s" (fstar-issue-message-with-level (car local-issues)))))))

;;; ;; Visiting related errors

(defun fstar-jump-to-related-error (&optional display-action)
  "Jump to secondary error location of error at point.
DISPLAY-ACTION is nil, `window', or `frame'."
  (interactive)
  (-if-let* ((loc (car (fstar-subp--alt-locs-at (point)))))
      (fstar--navigate-to loc display-action)
    (if (fstar-subp--in-issue-p (point))
        (user-error "No secondary locations for this issue")
      (user-error "No error here"))))

(defun fstar-jump-to-related-error-other-window ()
  "Jump to secondary location of error at point in new window."
  (interactive)
  (fstar-jump-to-related-error 'window))

(defun fstar-jump-to-related-error-other-frame ()
  "Jump to secondary location of error at point in new frame."
  (interactive)
  (fstar-jump-to-related-error 'frame))

;;; ;; Tracking and updating overlays

(defun fstar-subp-status (overlay)
  "Get status of OVERLAY."
  (overlay-get overlay 'fstar-subp-status))

(defun fstar-subp-status-eq (overlay status)
  "Check if OVERLAY has status STATUS."
  (eq (fstar-subp-status overlay) status))

(defun fstar-subp-remove-unprocessed ()
  "Remove pending and busy overlays."
  (cl-loop for overlay in (fstar-subp-tracking-overlays)
           unless (fstar-subp-status-eq overlay 'processed)
           do (delete-overlay overlay)))

(defun fstar-subp-legacy--strip-comments (str)
  "Remove comments in STR (replace them with spaces).
This was needed when control and data were mixed."
  (with-temp-buffer
    (set-syntax-table fstar-syntax-table)
    (fstar-setup-comments)
    (comment-normalize-vars)
    (insert str)
    (goto-char (point-min))
    (let (start)
      (while (setq start (comment-search-forward nil t))
        (goto-char start)
        (forward-comment 1)
        (save-match-data
          (let* ((comment (buffer-substring-no-properties start (point)))
                 (replacement (replace-regexp-in-string "." " " comment t t)))
            (delete-region start (point))
            (insert replacement)))))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun fstar-subp--clean-buffer-substring (beg end)
  "Make a clean copy of range BEG..END before sending it to F*."
  (if (fstar--has-feature 'json-subp)
      (buffer-substring-no-properties beg end)
    (fstar-subp-legacy--strip-comments (buffer-substring-no-properties beg end))))

(defun fstar-subp--push-peek-query-1 (query pos kind code)
  "Helper for push/peek (QUERY) with POS KIND and CODE."
  (make-fstar-subp-query
   :query query
   :args `(("kind" . ,(symbol-name kind))
           ("code" . ,code)
           ("line" . ,(line-number-at-pos pos))
           ("column" . ,(fstar-subp--column-number-at-pos pos)))))

(defun fstar-subp--push-query (pos kind code)
  "Prepare a push query for a region starting at POS.
KIND is one of `lax', `full'.  CODE is the code to push."
  (if (fstar--has-feature 'json-subp)
      (fstar-subp--push-peek-query-1 "push" pos kind code)
    (format "#push %d %d%s\n%s%s"
            (line-number-at-pos pos)
            (fstar-subp--column-number-at-pos pos)
            (pcase kind (`lax " #lax") (`full ""))
            code
            fstar-subp-legacy--footer)))

(defun fstar-subp--peek-query (pos kind code)
  "Prepare a peek query for a region starting at POS.
KIND is one of `syntax' or `light'.  CODE is the code to
push."
  (fstar-assert (fstar--has-feature 'json-subp))
  (fstar-subp--push-peek-query-1 "peek" pos kind code))

(defun fstar-subp--warn-about-renames ()
  "Warn if the current buffer was renamed since F* was started."
  (let ((fname (fstar-subp--buffer-file-name))
        (original-fname (car fstar-subp--prover-args)))
    (unless (equal fname original-fname)
      (warn "F*: Current file was renamed (%s → %s; \
dependency computations may be wrong." original-fname fname))))

(defun fstar-subp--vfs-add-query ()
  "Prepare a vfs-add query for the current buffer."
  (fstar-subp--warn-about-renames)
  (let ((contents (fstar--prog-widened-excursion
                    (buffer-substring-no-properties (point-min) (point-max)))))
    (make-fstar-subp-query
     :query "vfs-add"
     :args `(("filename" . nil) ;; `nil' means "use the current file"
             ("contents" . ,contents)))))

(defun fstar-subp--send-current-file-contents ()
  "Tell F* about edits in the current buffer not yet reflected to disk."
  (fstar-subp-start) ;; Ensure the feature list is loaded
  (when (fstar--has-feature 'vfs-add)
    (fstar-subp--query (fstar-subp--vfs-add-query) #'ignore)))

(defun fstar-subp-push-region (beg end kind continuation)
  "Push the region between BEG and END to the inferior F* process.
KIND indicates how to check BEG..END (one of `lax', `full').
Handle results with CONTINUATION."
  (let* ((payload (fstar-subp--clean-buffer-substring beg end)))
    (when (eq beg (point-min)) (fstar-subp--send-current-file-contents))
    (fstar-subp--query (fstar-subp--push-query beg kind payload) continuation)))

(defun fstar-subp-peek-region (beg end kind continuation)
  "Ask the inferior F* process about the region between BEG and END.
KIND indicates how to check BEG..END (one of `syntax', `light').
Handle results with CONTINUATION."
  (let* ((payload (fstar-subp--clean-buffer-substring beg end)))
    (fstar-subp--query (fstar-subp--peek-query beg kind payload) continuation)))

(defun fstar-subp-overlay-attempt-modification (overlay _is-before beg end &optional _pre-length)
  "Allow or prevent attempts to modify contents of OVERLAY in BEG..END.

Modifications are only allowed if it is safe to retract up to the
beginning of the current overlay."
  (let ((inhibit-modification-hooks t))
    (when (overlay-buffer overlay) ;; Hooks can be called multiple times
      (fstar--widened
        (cond
         ;; Allow edits in comments.  This heuristic isn't enough (it allows RET
         ;; in // comments, for example), but the consensus is that minor
         ;; inconsistencies are better than disabling edits entirely.  See
         ;; `https://github.com/FStarLang/fstar-mode.el/issues/89' for details.
         ((and (fstar-in-comment-p beg)
               (equal (fstar--comment-beginning beg)
                      (fstar--comment-beginning end)))
          t)
         ;; Allow modifications (after retracting) in all overlays if F* isn't
         ;; busy, and in pending overlays only otherwise
         ((or (not (fstar-subp--busy-with-overlays-p))
              (fstar-subp-status-eq overlay 'pending))
          (fstar-subp-retract-until (overlay-start overlay)))
         ;; Disallow modifications in processed overlays when F* is busy
         ((fstar-subp-status-eq overlay 'processed)
          (user-error "Cannot retract a processed section while F* is busy"))
         ;; Always disallow modifications in busy overlays
         ((fstar-subp-status-eq overlay 'busy)
          (user-error "Cannot retract a busy section")))))))

(defun fstar-subp--status-face (status lax)
  "Get face for STATUS, optionally with LAX modifier."
  (intern (format "fstar-subp-overlay-%s-%sface" (symbol-name status)
                  (if lax "lax-" ""))))

(defun fstar-subp-set-status (overlay status)
  "Set status of OVERLAY to STATUS."
  (fstar-assert (memq status fstar-subp-statuses))
  (let* ((inhibit-read-only t)
         (lax (overlay-get overlay 'fstar-subp--lax))
         (help-echo (propertize " " 'fstar-subp--legend (current-buffer))))
    (overlay-put overlay 'fstar-subp-status status)
    (overlay-put overlay 'priority -1)
    (overlay-put overlay 'help-echo help-echo)
    (overlay-put overlay 'face (fstar-subp--status-face status lax))
    (overlay-put overlay 'insert-in-front-hooks '(fstar-subp-overlay-attempt-modification))
    (overlay-put overlay 'modification-hooks '(fstar-subp-overlay-attempt-modification))))

(defun fstar-subp-process-overlay (overlay)
  "Send the contents of OVERLAY to the underlying F* process."
  (fstar-assert (not (fstar-subp--busy-p)))
  (fstar-subp-start)
  (fstar-subp-set-status overlay 'busy)
  (let ((lax (overlay-get overlay 'fstar-subp--lax)))
    (fstar-subp-push-region
     (overlay-start overlay) (overlay-end overlay) (if lax 'lax 'full)
     (apply-partially #'fstar-subp--overlay-continuation overlay))))

(defun fstar-subp--set-queue-timer ()
  "Set the queue timer for the current buffer."
  (unless fstar-subp--queue-timer
    (setq fstar-subp--queue-timer
          (run-with-timer 0 nil #'fstar-subp-process-queue (current-buffer)))))

(defun fstar-subp-process-queue (buffer)
  "Process the next pending overlay of BUFFER, if any."
  (with-current-buffer buffer
    (setq fstar-subp--queue-timer nil)
    (fstar-subp-start)
    (fstar--widened
      (unless (fstar-subp--busy-p)
        (-if-let* ((overlay (car (fstar-subp-tracking-overlays 'pending))))
            (progn (fstar-log 'info "Processing queue")
                   (fstar-subp-process-overlay overlay))
          (fstar-log 'info "Queue is empty (%d overlays)"
                (length (fstar-subp-tracking-overlays))))))))

;;; ;; Moving around the buffer

(defcustom fstar-fly-past-comments t
  "Whether to skip comments when splitting blocks to send to F*."
  :group 'fstar-interactive
  :type 'boolean
  :safe #'booleanp)

(defconst fstar-subp--blanks-re "[ \n\r\t]*")

(defconst fstar-subp-block-sep
  (let ((two-or-more-blank-lines "\n\\(?:[ \t\r]*\n\\)+"))
    ;; `fstar-comment-start-skip' handles cases like ‘// blah\nlet a = 1’
    ;; False positives are handled in `fstar-subp--likely-block-start-p'.
    (format "\\`%s\\(?1:\\)\\|%s\\(?1:\\)\\'\\|%s\\(?1:^\\)\\(%s\\|%s\\)"
            fstar-subp--blanks-re fstar-subp--blanks-re two-or-more-blank-lines
            fstar-comment-start-skip fstar-syntax-block-start-re)))

(defconst fstar-subp-block-start-re
  (format "\\`\\|%s\\(?:\\'\\|^\\(?:%s\\)\\)" fstar-subp--blanks-re fstar-syntax-block-start-re))

(defun fstar-subp--likely-block-start-p ()
  "Check whether the current match looks like a block start."
  (and
   ;; Skip block starters in comments
   (not (fstar-in-comment-p (match-beginning 1)))
   ;; Skip false positives introduced by considering ‘^//’ a block starter
   (save-excursion
     (goto-char (match-beginning 0))
     (while (forward-comment 1))
     (skip-chars-backward fstar--spaces)
     (looking-at-p fstar-subp-block-start-re))))

(defun fstar-subp--block-start-p ()
  "Check whether the current match is a valid block start."
  (and (not (= (match-beginning 1) (point-max)))
       (fstar-subp--likely-block-start-p)))

(defun fstar-subp--block-end-p ()
  "Check whether the current match is a valid block end."
  (and (not (= (match-beginning 0) (point-min)))
       (fstar-subp--likely-block-start-p)))

(defun fstar-subp-previous-block-start ()
  "Go to and return beginning of current block.
When point is at beginning of block, go to previous block."
  (interactive)
  (when (save-excursion
          ;; Find an appropriate starting point
          (unless (eq (point) (point-at-bol))
            (goto-char (point-at-eol)))
          ;; Jump to previous block separator
          (fstar--re-search-predicated-backward
           #'fstar-subp--block-start-p fstar-subp-block-sep))
    (goto-char (match-beginning 1))))

(defun fstar-subp-next-block-start ()
  "Go to and return beginning of next block (if any)."
  (interactive)
  (when (save-excursion
          ;; Find appropriate starting point
          (goto-char (point-at-eol))
          (skip-chars-backward fstar--spaces)
          ;; Ensure progress
          (when (bobp) (forward-char))
          ;; Jump to next block separator
          (fstar--re-search-predicated-forward
           #'fstar-subp--block-start-p fstar-subp-block-sep))
    (goto-char (match-beginning 1))))

(defun fstar-subp-next-block-end ()
  "Go to end of current block."
  (interactive)
  (when (save-excursion
          ;; Find appropriate starting point
          (goto-char (point-at-eol))
          ;; Jump to next block separator
          (fstar--re-search-predicated-forward
           #'fstar-subp--block-end-p fstar-subp-block-sep))
    (goto-char (match-beginning 1))))

(defun fstar-subp--next-point-to-process ()
  "Find the end of the next block to process.
Returns nil (but still moves point) if search fails."
  (if fstar-fly-past-comments
      (while (forward-comment 1))
    (skip-chars-forward fstar--spaces))
  (fstar-subp-next-block-end))

(defun fstar-subp--find-point-to-process (n)
  "Find the end of the (at most) N th block to process.
Return nil if search fails.  This is a rare case (because the
block sep regexp usually matches the end of the buffer), but it
can still happen (with the default block sep) if the end of the
buffer is in a comment that doesn't start in column 0."
  (save-excursion
    (let ((final-point nil))
      (fstar-subp--untracked-beginning)
      (dotimes (_ n)
        (when (fstar-subp--next-point-to-process)
          (setq final-point (point))))
      final-point)))

(defun fstar-subp--untracked-beginning-position ()
  "Find the beginning of the untracked buffer area."
  (or (cl-loop for overlay in (fstar-subp-tracking-overlays)
               maximize (overlay-end overlay))
      (point-min)))

(defun fstar-subp--untracked-beginning ()
  "Go to beginning of untracked buffer area."
  (goto-char (fstar-subp--untracked-beginning-position)))

(defun fstar-subp-goto-beginning-of-untracked-region ()
  "Go to start of first untracked block."
  (interactive)
  (fstar-subp--untracked-beginning)
  (unless (bobp) (fstar-subp-next-block-start)))

(defun fstar-subp--unprocessed-beginning-position ()
  "Find the beginning of the untracked buffer area."
  (or (cl-loop for overlay in (fstar-subp-tracking-overlays 'pending)
               minimize (overlay-start overlay))
      (fstar-subp--untracked-beginning-position)))

(defun fstar-subp-goto-beginning-of-unprocessed-region ()
  "Go to start of first untracked block."
  (interactive)
  (goto-char (fstar-subp--unprocessed-beginning-position))
  (unless (bobp) (fstar-subp-next-block-start)))

(defalias 'fstar-subp-goto-beginning-of-unprocessed
  'fstar-subp-goto-beginning-of-unprocessed-region)

;;; ;; Advancing and retracting

(defun fstar-subp-enqueue-until (end &optional no-error)
  "Mark region up to END busy, and enqueue the newly created overlay.
Report an error if the region is empty and NO-ERROR is nil."
  (fstar-subp-start)
  (let ((beg (fstar-subp--untracked-beginning-position))
        (end (save-excursion (goto-char end) (skip-chars-backward fstar--spaces) (point))))
    (if (<= end beg)
        (unless no-error
          (user-error "Region up to point is empty: nothing to process!"))
      (when (eq (char-after end) ?\n)
        (cl-incf end))
      (fstar-assert (cl-loop for overlay in (overlays-in beg end)
                        never (fstar-subp-tracking-overlay-p overlay)))
      (let ((overlay (make-overlay beg end (current-buffer) nil nil))
            (fstar-subp--lax (or fstar-subp--lax fstar-subp-sloppy)))
        (fstar-subp-remove-orphaned-issue-overlays (point-min) (point-max))
        (overlay-put overlay 'fstar-subp--lax fstar-subp--lax)
        (fstar-subp-set-status overlay 'pending)
        (fstar-subp--set-queue-timer)))))

(defun fstar-subp-advance-next (&optional lax)
  "Process next block, possibly (with prefix arg) in LAX mode."
  (interactive "P")
  (fstar-subp-start)
  (fstar--widened
    (-if-let* ((target (fstar-subp--find-point-to-process 1)))
        (let ((fstar-subp--lax lax))
          (fstar-subp-enqueue-until (goto-char target)))
      (user-error "Cannot find a full block to process"))))

(defun fstar-subp-advance-next-lax ()
  "Process next block in LAX mode."
  (interactive)
  (fstar-subp-advance-next t))

(defun fstar-subp-pop-overlay (overlay)
  "Remove overlay OVERLAY and issue the corresponding `pop' command."
  ;; F* might be busy, but not with overlays
  (fstar-assert (null (fstar-subp-tracking-overlays 'busy)))
  (delete-overlay overlay)
  (fstar-subp--pop))

(defun fstar-subp-retract-one (overlay)
  "Retract OVERLAY, with some error checking."
  (cond
   ((not (fstar-subp-live-p)) (user-error "F* subprocess not started"))
   ((not overlay) (user-error "Nothing to retract!"))
   ((fstar-subp-status-eq overlay 'pending) (delete-overlay overlay))
   ((fstar-subp-status-eq overlay 'busy) (user-error "Cannot retract busy regions"))
   ((fstar-subp-status-eq overlay 'processed) (fstar-subp-pop-overlay overlay))))

(defun fstar-subp-retract-last ()
  "Retract last processed block."
  (interactive)
  (fstar--widened
    (fstar-subp-retract-one (car (last (fstar-subp-tracking-overlays))))
    (fstar-subp-goto-beginning-of-untracked-region)))

(defun fstar-subp-retract-until (pos)
  "Retract blocks until POS is in untracked region."
  (fstar--widened
    (cl-loop for overlay in (reverse (fstar-subp-tracking-overlays))
             when (> (overlay-end overlay) pos) ;; End point is not inclusive
             do (fstar-subp-retract-one overlay))))

(defun fstar-subp-advance-until (pos)
  "Submit or retract blocks to/from prover until POS (included)."
  (fstar-subp-start)
  (fstar--widened-excursion
    (let ((found nil))
      (fstar-subp--untracked-beginning)
      (while (and (not (eobp)) ;; Don't loop at eob
                  (fstar-subp--next-point-to-process)
                  (<= (point) pos))
        ;; ⚠ This fails when there's nothing left but blanks to process.
        ;; (which in fact makes the (not (eobp)) check above redundant.)
        (fstar-subp-enqueue-until (point))
        (setq found t))
      (fstar-subp-enqueue-until pos found))))

(defun fstar-subp-reload-to-point (pos lax)
  "Retract everything and process (possibly in LAX mode) again to POS."
  (interactive (list (point) (not (null current-prefix-arg))))
  (fstar-subp-start)
  (fstar--widened
    (fstar-subp-retract-until (point-min))
    (let ((fstar-subp--lax lax))
      (fstar-subp-advance-until pos))))

(defun fstar-subp-advance-or-retract-to-point (&optional arg)
  "Advance or retract proof state to reach point.

With prefix argument ARG, when advancing, do not split region
into blocks; process it as one large block instead."
  (interactive "P")
  (fstar-subp-start)
  (fstar--widened
    (cond
     ((fstar-subp--in-tracked-region-p)
      (fstar-subp-retract-until (point)))
     ((consp arg)
      (fstar-subp-enqueue-until (point)))
     (t
      (fstar-subp-advance-until (point))))))

(defun fstar-subp-advance-or-retract-to-point-lax (&optional arg)
  "Like `fstar-subp-advance-or-retract-to-point' with ARG, in lax mode."
  (interactive "P")
  (let ((fstar-subp--lax t))
    (fstar-subp-advance-or-retract-to-point arg)))

(defun fstar-subp-advance-to-point-max-lax (&optional arg)
  "Like `fstar-subp-advance-or-retract-to-point' on `point-max', in lax mode.
Pass ARG to `fstar-subp-advance-or-retract-to-point'."
  (interactive "P")
  (let ((fstar-subp--lax t))
    (fstar--widened-excursion
      (goto-char (point-max))
      (fstar-subp-advance-or-retract-to-point arg))))

;;; ;; Features based on subp

;;; ;; ;; Dynamic Flycheck

(defun fstar-subp--can-run-flycheck ()
  "Check whether it's a reasonable time to start a syntax check."
  (and (fstar-subp-available-p)
       (null (fstar-subp-tracking-overlays 'pending))))

(defun fstar-subp--make-flycheck-issue (issue)
  "Convert an F* ISSUE to a Flycheck issue."
  (-when-let* ((loc (car (fstar-issue-locs issue))))
    (flycheck-error-new-at
     (fstar-location-line-from loc)
     (1+ (fstar-location-col-from loc))
     (fstar-issue-level issue)
     (fstar-issue-message issue)
     :checker 'fstar-interactive
     :filename (fstar-location-remote-filename loc))))

(defun fstar-subp--flycheck-continuation (callback status response)
  "Forward results of Flycheck check (STATUS and RESPONSE) to CALLBACK."
  (if (memq status '(interrupted failure))
      ;; `failure' can be returned when we run a peek query after starting F* on
      ;; an invalid file.  The first push fails, and so do subsequent peeks.
      (funcall callback 'interrupted nil)
    (let* ((raw-issues (fstar-subp-parse-issues response))
           (issues (mapcar #'fstar-subp-cleanup-issue raw-issues)))
      (fstar-log 'info "Highlighting Flycheck issues: %S" issues)
      (funcall callback 'finished
               (delq nil (mapcar #'fstar-subp--make-flycheck-issue issues))))))

(defcustom fstar-subp-flycheck-lookahead 3
  "Number of blocks to check continuously, in the background."
  :group 'fstar-interactive
  :type 'integer)

(defcustom fstar-subp-flycheck-level 'lax
  "Stringency level of continuous Flycheck checking."
  :group 'fstar-interactive
  :type '(choice (const :tag "Syntax only" syntax)
                 (const :tag "Syntax + lax typechecking" lax)))

(defun fstar-subp--start-syntax-check (_checker callback)
  "Start a light syntax check; pass results to CALLBACK."
  (fstar--widened
    (if (fstar-subp--can-run-flycheck)
        (let ((beg (fstar-subp--untracked-beginning-position))
              (end (fstar-subp--find-point-to-process fstar-subp-flycheck-lookahead)))
          (if (and (numberp end) (< beg end))
              (fstar-subp-peek-region
               beg end fstar-subp-flycheck-level
               (apply-partially #'fstar-subp--flycheck-continuation callback))
            (funcall callback 'finished nil)))
      (funcall callback 'interrupted nil))))

(defun fstar--flycheck-verify-subp-available ()
  "Create a verification result announcing availability of the F* subprocess."
  (list
   (flycheck-verification-result-new
    :label "Subprocess started"
    :message (if (fstar-subp-live-p) "OK, F* started"
               "This checker requires a running F* subprocess.")
    :face (if (fstar-subp-live-p) 'success '(bold error)))
   (flycheck-verification-result-new
    :label "Subprocess available"
    :message (if (fstar-subp-available-p) "OK, F* idle"
               "This checker only runs when the F* subprocess is idle.")
    :face (if (fstar-subp-available-p) 'success '(bold error)))))

(flycheck-define-generic-checker 'fstar-interactive
  "Flycheck checker for F*'s interactive mode.
This checker uses the F* subprocess to do light real-time
checking of the first few chunks of the untracked region of the
buffer."
  :start #'fstar-subp--start-syntax-check
  :modes '(fstar-mode)
  :verify (lambda (checker) (append (fstar--flycheck-verify-enabled checker)
                               (fstar--flycheck-verify-subp-available)))
  :predicate (lambda ()
               (and (fstar--has-feature 'peek)
                    (eq fstar-flycheck-checker 'fstar-interactive)
                    (fstar-subp--can-run-flycheck))))

(add-to-list 'flycheck-checkers 'fstar-interactive)

;;; ;; ;; Lookup queries

;;; ;; ;; ;; Result types and views

(cl-defstruct (fstar-lookup-result
               (:constructor nil))
  name doc def-loc)

(cl-defstruct (fstar-symbol-info
               (:include fstar-lookup-result))
  type def)

(cl-defstruct (fstar-option-info
               (:include fstar-lookup-result))
  sig value default type permission-level)

(cl-defstruct (fstar-ns-or-mod-info
               (:include fstar-lookup-result))
  kind loaded)

(defun fstar-lookup-result--doc-keybinding-hint (info help-key)
  "Compute a message suggesting to use HELP-KEY for docs on INFO.
Return nil if INFO doesn't include documentation."
  (if (fstar-lookup-result-doc info)
      (substitute-command-keys (format " (%s for help)" help-key))))

(defun fstar-lookup-result-docstring (info)
  "Format docstring of INFO, if any."
  (-when-let* ((doc (fstar-lookup-result-doc info)))
    (cl-typecase info
      (fstar-option-info doc)
      (otherwise (fstar--highlight-docstring doc)))))

(defun fstar-symbol-info-sig (symbol-info)
  "Format signature of SYMBOL-INFO."
  (fstar-highlight-string (format "%s: %s"
                             (fstar-symbol-info-name symbol-info)
                             (fstar-symbol-info-type symbol-info))))

(defun fstar-option-info-propertized-sig (info)
  "Fontify and return (`fstar-option-info-sig' INFO)."
  (let ((sig (fstar-option-info-sig info)))
    (string-match "\\([^ ]+\\)\\(.*\\)" sig)
    (concat
     (propertize (match-string 1 sig) 'face 'font-lock-function-name-face)
     (propertize (match-string 2 sig) 'face 'font-lock-variable-name-face))))

(defun fstar-lookup-result--help-ticker (info help-key)
  "Compute a single-line documentation string from INFO.
HELP-KEY: See `fstar-lookup-result--doc-keybinding-hint'."
  (concat
   (fstar--strip-newlines
    (cl-etypecase info
      (fstar-symbol-info
       (fstar-symbol-info-sig info))
      (fstar-option-info
       (format "%s: %s (%s, currently %s, default %s)"
               (fstar-option-info-propertized-sig info)
               (propertize (or (fstar-option-info-doc info) "[undocumented]")
                           'face 'font-lock-doc-face)
               (propertize (fstar-option-info-type info) 'face 'font-lock-type-face)
               (fstar-subp--option-val-to-string (fstar-option-info-value info))
               (fstar-subp--option-val-to-string (fstar-option-info-default info))))
      (fstar-ns-or-mod-info
       (concat
        (propertize (fstar-ns-or-mod-info-kind info) 'face 'fstar-structure-face)
        " " (propertize (fstar-ns-or-mod-info-name info) 'face 'font-lock-type-face)
        (-when-let* ((path (fstar-ns-or-mod-info-def-loc info)))
          (format " (in %s)" (propertize path 'face 'italic)))
        (unless (fstar-ns-or-mod-info-loaded info)
          (let ((msg "not loaded: use, save your file, \
and reset or restart F* to load"))
            (format " (%s)" (propertize msg 'face 'font-lock-warning-face))))))))
   (unless (fstar-option-info-p info)
     (fstar-lookup-result--doc-keybinding-hint info help-key))))

;;; ;; ;; ;; Implementation

(defconst fstar--command-line-option-prefix-re
  "--[-_.0-9A-Za-z]*")

(defun fstar-subp--context-at-point ()
  "Compute context at point.
Must be called with syntax table `fstar--fqn-at-point-syntax-table'"
  (let ((line-context
         (save-excursion
           (goto-char (point-at-bol))
           (cond
            ((looking-at-p "open ") 'open)
            ((looking-at-p "include ") 'include)
            ((looking-at-p "module \\(?:\\s_\\|\\sw\\)+ *=") 'module-alias)
            ((looking-at-p "#set-options") 'set-options)
            ((looking-at-p "#reset-options") 'reset-options)))))
    (cond
     ((memq line-context '(open include module-alias))
      line-context)
     ((memq line-context '(set-options reset-options))
      (when (looking-back fstar--command-line-option-prefix-re (point-at-bol))
        line-context))
     ((looking-back "\\_<let open [^ \n]*" (point-at-bol))
      'let-open)
     (t 'code))))

(defun fstar-subp--positional-lookup-query (pos fields)
  "Prepare a header for an info query at POS with FIELDS."
  (declare (indent 1))
  (if (fstar--has-feature 'json-subp)
      (make-fstar-subp-query
       :query "lookup"
       :args `(("context" . ,(symbol-name (or (fstar-subp--context-at-point) 'code)))
               ("symbol" . ,(or (fstar--fqn-at-point pos) ""))
               ("requested-info" . ,fields)
               ("location" .
                (("filename" . ,(buffer-file-name))
                 ("line" . ,(line-number-at-pos pos))
                 ("column" . ,(fstar-subp--column-number-at-pos pos))))))
    (if (fstar--has-feature 'info-includes-symbol)
        (format "#info %s <input> %d %d"
                (or (fstar--fqn-at-point pos) "")
                (line-number-at-pos pos)
                (fstar-subp--column-number-at-pos pos))
      (format "#info <input> %d %d"
              (line-number-at-pos pos)
              (fstar-subp--column-number-at-pos pos)))))

(defun fstar-subp--positionless-lookup-query (symbol fields context)
  "Prepare a header for an info query for SYMBOL with FIELDS.
CONTEXT indicates where SYMBOL comes from."
  (declare (indent 1))
  (when (equal symbol "")
    (user-error "Looking up an empty name"))
  (if (fstar--has-feature 'json-subp)
      (make-fstar-subp-query
       :query "lookup"
       :args `(("symbol" . ,symbol)
               ("context" . ,context)
               ("requested-info" . ,fields)))
    (format "#info %s" symbol)))

(defconst fstar-subp-legacy--info-response-header-regex
  "^(defined at \\(.+?\\)(\\([0-9]+\\),\\([0-9]+\\)-\\([0-9]+\\),\\([0-9]+\\))) *\\([^ ]+\\) *: +")

(defconst fstar-subp-legacy--info-response-body-regex
  "\\([^\0]+?\\)\\(?:#doc \\([^\0]+?\\)\\)?\\'")

(defun fstar-subp-legacy--parse-info (response)
  "Parse info structure from RESPONSE."
  (when (string-match fstar-subp-legacy--info-response-header-regex response)
    (pcase-let* ((body (substring response (match-end 0)))
                 (`(,file ,start-r ,start-c ,end-r ,end-c ,name)
                  (mapcar #'fstar--string-trim
                          (fstar--match-strings-no-properties
                           '(1 2 3 4 5 6) response)))
                 (`(,type ,doc)
                  (and (string-match fstar-subp-legacy--info-response-body-regex body)
                       (mapcar #'fstar--string-trim (fstar--match-strings-no-properties
                                                '(1 2) body)))))
      (make-fstar-symbol-info
       :name name
       :def-loc (make-fstar-location
                 :filename file
                 :line-from (string-to-number start-r)
                 :line-to (string-to-number end-r)
                 :col-from (string-to-number start-c)
                 :col-to (string-to-number end-c))
       :type (and type (fstar--unparens type))
       :doc (fstar--string-trim doc)
       :def nil))))

(defun fstar-subp-json--parse-defined-at (defined-at)
  "Parse DEFINED-AT part of lookup result."
  (when (fstar--lispify-null defined-at)
    (let-alist defined-at
      (make-fstar-location
       :filename (fstar-subp--fixup-fname .fname)
       :line-from (elt .beg 0)
       :col-from (elt .beg 1)
       :line-to (elt .end 0)
       :col-to (elt .end 1)))))

(defun fstar-subp-json--parse-info (json)
  "Parse info structure from JSON."
  (pcase (or (cdr (assq 'kind json)) "symbol")
    ("symbol"
     (let-alist json
       (make-fstar-symbol-info
        :name .name
        :doc (fstar--string-trim (fstar--lispify-null .documentation))
        :def-loc (fstar-subp-json--parse-defined-at .defined-at)
        :type (fstar--unparens (fstar--lispify-null .type)) ;; FIXME remove once F* is fixed
        :def (fstar--unparens (fstar--lispify-null .definition)))))
    ("option"
     (let-alist json
       (make-fstar-option-info
        :name .name :doc (fstar--lispify-null .documentation)
        :def-loc nil :sig .signature :value .value :default .default
        :type .type :permission-level .permission-level)))
    ((or "module" "namespace")
     (let-alist json
       (make-fstar-ns-or-mod-info
        :name .name :doc nil :def-loc .path :kind .kind
        :loaded (fstar--lispify-false .loaded))))
    (other
     (message "Unrecognized info kind: %s.  Try updating fstar-mode." other))))

(defun fstar-subp--pos-check-wrapper (pos continuation)
  "Construct a continuation that runs CONTINUATION if point is POS.
Otherwise, call CONTINUATION with nil.  If POS is nil, the POS
check is ignored."
  (declare (indent 1))
  (lambda (status response)
    (if (or (null pos) (eq (point) pos))
        (funcall continuation status response)
      (funcall continuation 'interrupted nil))))

(defun fstar-subp--lookup-wrapper (pos continuation)
  "Handle the results of a lookup query at POS.
If response is valid, forward results (deserialized into one of
the various lookup result types) to CONTINUATION.  With nil POS,
this function can also handle results of position-less lookup
queries."
  (declare (indent 1))
  (fstar-subp--pos-check-wrapper pos
    (lambda (status response)
      (-if-let* ((info (and (eq status 'success)
                            (if (fstar--has-feature 'json-subp)
                                (fstar-subp-json--parse-info response)
                              (fstar-subp-legacy--parse-info response)))))
          (funcall continuation info)
        (funcall continuation nil)))))

(defun fstar--eldoc-continuation (continuation info) ;; Branch on type of info
  "Pass eldoc string derived from INFO (if non-nil) to CONTINUATION."
  (when info
    (funcall continuation (fstar-lookup-result--help-ticker info "\\[fstar-doc]"))))

(defun fstar--eldoc-function ()
  "Compute an eldoc string for current point.
Briefly tries to get results synchronously to reduce flicker, and
then returns nil (in that case, results are displayed
asynchronously after the fact)."
  (-if-let* ((hole-info (get-text-property (point) 'fstar--match-var-type)))
      (format "This hole has type `%s'" (car hole-info))
    (when (and (fstar--has-feature 'lookup) (fstar-subp-available-p)
               (not (fstar-subp--in-issue-p (point))))
      (let* ((query (fstar-subp--positional-lookup-query (point)
                      '(type documentation))) ;; Needs docs for C-c C-s C-d hint
             (retv (fstar-subp--query-and-wait query 0.01)))
        (pcase retv
          (`(t . (,status ,results))
           (funcall (fstar-subp--lookup-wrapper (point)
                      (apply-partially #'fstar--eldoc-continuation #'identity))
                    status results))
          (`(needs-callback . ,_)
           (setf (cdr retv)
                 (fstar-subp--lookup-wrapper (point)
                   (apply-partially #'fstar--eldoc-continuation #'eldoc-message)))
           nil))))))

(defun fstar--eldoc-truncate-message (fn &rest args)
  "Forward ARGS to FN within scope of binding for `message-truncate-lines'."
  (if (derived-mode-p 'fstar-mode)
      (let ((message-truncate-lines t))
        (apply fn args))
    (apply fn args)))

(defun fstar-setup-eldoc ()
  "Set up eldoc support."
  ;; Add-function doesn't work on 'eldoc-documentation-function in Emacs < 25,
  ;; due to the default value being nil instead of `ignore'.
  (setq-local eldoc-documentation-function #'fstar--eldoc-function)
  ;; A better default, since it's pretty crucial in fstar-mode
  (setq-local eldoc-idle-delay 0.1)
  ;; LATER the following should move to yasnippet itself
  (eldoc-add-command 'yas-next-field-or-maybe-expand 'yas-prev-field
                     'yas-expand 'yas-expand-from-keymap
                     'yas-expand-from-trigger-key)
  (when (fboundp 'advice-add)
    (advice-add 'eldoc-message :around #'fstar--eldoc-truncate-message))
  (eldoc-mode))

(defun fstar-teardown-eldoc ()
  "Tear down eldoc support."
  (kill-local-variable 'eldoc-documentation-function)
  (when (fboundp 'advice-remove)
    (advice-remove 'eldoc-message #'fstar--eldoc-truncate-message)))

;;; ;; ;; Doc at point

(defconst fstar--doc-buffer-name "*fstar: doc*")
(push fstar--doc-buffer-name fstar--all-temp-buffer-names)

(defun fstar--doc-buffer-populate-1 (title value)
  "Insert TITLE and VALUE to current buffer."
  (declare (indent 1))
  (when value
    (insert "\n\n" (propertize title 'face '(:height 0.9))
            "\n" (fstar--indent-str value 2))))

(defun fstar--doc-buffer-populate (info)
  "Compute contents of doc buffer from INFO."
  (let* ((doc (fstar-lookup-result-doc info))
         (name (fstar-lookup-result-name info))
         (title (fstar--propertize-title name))
         (def-loc (fstar-lookup-result-def-loc info)))
    (cl-typecase info
      (fstar-symbol-info
       (when doc (setq doc (fstar--highlight-docstring doc)))))
    (save-excursion
      (insert title "\n")
      (when def-loc
        (fstar--insert-link def-loc '(:height 0.9 :inherit link) nil 'reuse))
      (cl-etypecase info
        (fstar-symbol-info
         (-when-let* ((type (fstar-symbol-info-type info)))
           (fstar--doc-buffer-populate-1 "Type" (fstar-highlight-string type)))
         (-when-let* ((def (fstar-symbol-info-def info)))
           (fstar--doc-buffer-populate-1 "Definition" (fstar-highlight-string def))))
        (fstar-option-info
         (fstar--doc-buffer-populate-1 "Type"
           (propertize (fstar-option-info-type info) 'face 'font-lock-type-face))
         (fstar--doc-buffer-populate-1 "Signature"
           (fstar-option-info-propertized-sig info))
         (fstar--doc-buffer-populate-1 "Current value"
           (fstar-subp--option-val-to-string (fstar-option-info-value info)))
         (fstar--doc-buffer-populate-1 "Default value"
           (fstar-subp--option-val-to-string (fstar-option-info-default info)))
         (fstar--doc-buffer-populate-1 "Permission level"
           (pcase (fstar-option-info-permission-level info)
             ("" "Can be used with #set-options and #reset-options")
             (perms perms))))
        (fstar-ns-or-mod-info
         (fstar--doc-buffer-populate-1 "Misc"
           (format "This %s is %s."
                   (fstar-ns-or-mod-info-kind info)
                   (if (fstar-ns-or-mod-info-loaded info) "loaded"
                     "not yet loaded.  \
Use it, save your file, then restart or reset F* to import it.")))))
      (fstar--doc-buffer-populate-1 "Documentation"
        (and doc (fstar--unwrap-paragraphs doc))))))

(defun fstar--doc-at-point-continuation (info)
  "Show documentation and type in INFO."
  (if info
      (with-help-window fstar--doc-buffer-name
        (with-current-buffer standard-output
          (fstar--doc-buffer-populate info)))
    (message "No information found.")))

(defun fstar-doc-at-point-dwim ()
  "Show documentation of identifier at point, if any."
  (interactive)
  (unless (and (eq last-command this-command)
               (fstar--hide-buffer fstar--doc-buffer-name))
    (fstar-subp--ensure-available #'user-error 'lookup/documentation)
    (fstar-subp--query (fstar-subp--positional-lookup-query (point)
                    '(type defined-at documentation))
                  (fstar-subp--lookup-wrapper (point)
                    #'fstar--doc-at-point-continuation))))

(defun fstar-doc (id)
  "Show information and documentation about ID.
Interactively, prompt for ID."
  (interactive '(interactive))
  (fstar-subp--ensure-available #'user-error 'lookup/documentation)
  (when (eq id 'interactive)
    (setq id (fstar--read-string "Show docs for%s: " (fstar--fqn-at-point))))
  (fstar-subp--query (fstar-subp--positionless-lookup-query id
                  '(type defined-at documentation) 'symbol-only)
                (fstar-subp--lookup-wrapper (point)
                  #'fstar--doc-at-point-continuation)))

;;; ;; ;; Print

(defun fstar-print (id)
  "Show definition of ID.
Interactively, prompt for ID."
  (interactive '(interactive))
  (fstar-subp--ensure-available #'user-error 'lookup/definition)
  (when (eq id 'interactive)
    (setq id (fstar--read-string "Show definition of%s: " (fstar--fqn-at-point))))
  (fstar-subp--query (fstar-subp--positionless-lookup-query id
                  '(type defined-at documentation definition) 'symbol-only)
                (fstar-subp--lookup-wrapper (point)
                  #'fstar--doc-at-point-continuation)))

;;; ;; ;; Insert a match

(defun fstar--split-match-var-annot (str)
  "Split var name and <<<>>> type annotation in STR."
  (save-match-data
    (if (string-match "\\(.+?\\)<<<\\(.+?\\)>>>" str)
        (let ((var (match-string 1 str))
              (type (match-string 2 str)))
          (cons var (list type)))
      (cons str nil))))

(defun fstar--prepare-match-snippet (snippet)
  "Prepare SNIPPET: add numbers and replace type annotations."
  (let ((counter 0))
    (replace-regexp-in-string
     "\\$\\(?:{\\(.+?\\)}\\|\\$\\)"
     (lambda (match)
       (pcase-let* ((name (or (match-string-no-properties 1 match) ""))
                    (`(,name . ,type) (fstar--split-match-var-annot name)))
         (propertize (format "${%d:%s}" (cl-incf counter) name)
                     'fstar--match-var-type type)))
     snippet t t)))

(defun fstar--format-one-branch (branch)
  "Format a single match BRANCH."
  (format "| %s -> $$" (replace-regexp-in-string "\\`(\\(.*\\))\\'" "\\1" branch)))

(defun fstar--insert-match-continuation (type response)
  "Handle RESPONSE to a `show-match' query.
TYPE is used in error messages"
  (-if-let* ((branches (and response
                            (if (fstar--has-feature 'json-subp)
                                response
                              (split-string response "\n")))))
      (let* ((name-str (car branches))
             (branch-strs (mapconcat #'fstar--format-one-branch (cdr branches) "\n"))
             (match (format "match ${%s} with\n%s" name-str branch-strs))
             (indented (fstar--indent-str match (current-column) t)))
        (fstar--expand-snippet (fstar--prepare-match-snippet indented)))
    (message "No match found for type `%s'." type)))

(defun fstar--read-type-name ()
  "Read a type name."
  (read-string "Type to match on \
(‘list’, ‘either’, ‘option (nat * _)’, …): "))

(defun fstar-subp--show-match-query (type)
  "Prepare a `show-match' query for TYPE."
  (setq type (replace-regexp-in-string "\n" " " type))
  (if (fstar--has-feature 'json-subp)
      (make-fstar-subp-query
       :query "show-match"
       :args `(("type" . ,type)))
    (format "#show-match %s" type)))

(defun fstar-insert-match (type)
  "Insert a match on TYPE at point."
  (interactive '(interactive))
  (fstar-subp--ensure-available #'user-error 'show-match)
  (when (eq type 'interactive)
    (setq type (fstar--read-type-name)))
  (fstar-subp--query (fstar-subp--show-match-query type)
                (fstar-subp--pos-check-wrapper (point)
                  (apply-partially #'fstar--insert-match-continuation type))))

(defun fstar--destruct-var-continuation (from to type status response)
  "Replace FROM..TO (with TYPE) with match from RESPONSE.
STATUS is the original query's status."
  (pcase (and (eq status 'success) (split-string response "\n"))
    (`nil
     (message "No match found for type `%s'." type))
    (`(,_name ,branch)
     (remove-text-properties from to '(fstar--match-var-type nil))
     (let ((yas-indent-line nil)
           (snip (fstar--prepare-match-snippet branch)))
       (fstar--expand-snippet snip from to)
       (fstar--refresh-eldoc)))
    (_
     (message "Can't destruct `%s' in place (it has more than one constructor)" type))))

(defun fstar--destruct-match-var-1 (from to type)
  "Replace FROM..TO by pattern matching on TYPE."
  (fstar-subp--ensure-available #'user-error 'show-match)
  (fstar-subp--query
   (fstar-subp--show-match-query type)
   (fstar-subp--pos-check-wrapper (point)
     (apply-partially #'fstar--destruct-var-continuation from to type))))

(defun fstar--destruct-match-var-at-point ()
  "Destruct match variable inserted with `fstar-insert-match'."
  (pcase (fstar--property-range (point) 'fstar--match-var-type)
    (`(,from ,to (,type))
     (fstar--destruct-match-var-1 from to type)
     t)))

(defun fstar-insert-match-dwim ()
  "Insert a match, or destruct the identifier at point.
This works in two steps: the first invocation prompts for a type
name and inserts a full match.  Subsequent invocations (on
variables of the constructors of the first match) just destruct
that variable."
  (interactive)
  (if (region-active-p)
      (fstar--destruct-match-var-1 (region-beginning) (region-end) (fstar--read-type-name))
    (or (fstar--destruct-match-var-at-point)
        (fstar-insert-match (fstar--read-type-name)))))

;;; ;; ;; Eval

(defun fstar-subp--eval-all-rules ()
  "Compute rules available to normalize terms."
  `("beta" "delta" "iota" "zeta"
    ,@(when (fstar--has-feature 'compute/reify) '("reify"))))

(defun fstar-subp--eval-rule-to-marker (rule)
  "Convert reduction RULE to a short string."
  (pcase rule
    ("beta" "β")
    ("delta" "δ")
    ("iota" "ι")
    ("zeta" "ζ")
    ("reify" (propertize "r" 'face '(:height 0.7)))
    ("pure-subterms" (propertize "p" 'face '(:height 0.7)))
    (r (user-error "Unknown reduction rule %s" r))))

(defun fstar--reduction-arrow (arrow rules)
  "Annotate ARROW with RULES."
  (concat (propertize arrow 'face 'minibuffer-prompt)
          (propertize rules ;;'display '(raise -0.3)
                      'face '((:height 0.7) minibuffer-prompt))))

(defun fstar-subp--eval-continuation (term rules status response)
  "Handle results (STATUS, RESPONSE) of evaluating TERM with RULES."
  (setq rules (mapconcat #'fstar-subp--eval-rule-to-marker rules ""))
  (pcase status
    (`success (message "%s%s%s%s%s"
                       (fstar-highlight-string term)
                       (if (string-match-p "\n" term) "\n" " ")
                       (fstar--reduction-arrow "↓" rules)
                       (if (string-match-p "\n" response) "\n" " ")
                       (fstar-highlight-string (fstar--unparens response))))
    (`failure (message "Evaluation of [%s] failed: %s"
                       (fstar-highlight-string term)
                       (fstar--string-trim response)))))

(defun fstar-subp--eval-query (term rules)
  "Prepare a `compute' query for TERM with specific reduction RULES."
  (make-fstar-subp-query :query "compute"
                         :args `(("term" . ,term)
                                 ("rules" . ,rules))))

(defun fstar-eval (term rules)
  "Reduce TERM with RULES in F* subprocess and display the result.
Interactively, use the current region or prompt for a term.  With
a prefix argument, prompt for rules as well."
  (interactive (list 'interactive (if current-prefix-arg 'interactive)))
  (fstar-subp--ensure-available #'user-error 'compute)

  (let ((all-rules (fstar-subp--eval-all-rules)))
    (when (eq rules 'interactive)
      (setq rules (completing-read-multiple
                   "Reduction rules (comma-separated): "
                   all-rules nil t nil nil nil)))
    (setq rules (or rules all-rules)))

  (when (eq term 'interactive)
    (setq term
          (fstar--read-string
           (format "Term to %s-reduce%%s: " (mapconcat #'fstar-subp--eval-rule-to-marker rules ""))
           (cond
            ((region-active-p)
             (buffer-substring-no-properties (region-beginning) (region-end)))
            ((eq (char-before) (if (fstar-in-comment-p) ?\] ?\)))
             (buffer-substring-no-properties
              (1- (point)) (save-excursion (backward-list) (1+ (point)))))
            (t (fstar--fqn-at-point))))))
  (setq term (fstar--string-trim term))
  (message "Reducing `%s'…" term)
  (fstar-subp--query (fstar-subp--eval-query term rules)
                (apply-partially #'fstar-subp--eval-continuation term rules)))

(defun fstar-eval-custom ()
  "List `fstar-eval-custom', but always prompt for rules."
  (interactive)
  (fstar-eval 'interactive 'interactive))

;;; ;; ;; Search

(defconst fstar--search-buffer-name "*fstar: search*")
(push fstar--search-buffer-name fstar--all-temp-buffer-names)

(defun fstar-subp--search-insert-result (result)
  "Insert formatted RESULT of search."
  (let-alist result
    (insert (propertize .lid 'face 'font-lock-function-name-face)
            (propertize  "\n" 'line-height `(nil . 1.5) 'line-spacing 0.2))
    (let ((from (point))
          (type (fstar--unparens .type)))
      (insert (fstar-highlight-string (fstar--indent-str type 2)))
      (font-lock-append-text-property from (point) 'face '(:height 0.9)))))

(defun fstar-subp--search-continuation (terms status response)
  "Handle results (STATUS, RESPONSE) of searching for TERMS."
  (pcase status
    (`success
     (with-help-window fstar--search-buffer-name
       (with-current-buffer standard-output
         (visual-line-mode)
         (when (fboundp 'adaptive-wrap-prefix-mode)
           (adaptive-wrap-prefix-mode))
         (dolist (result response)
           (fstar-subp--search-insert-result result)
           (insert "\n")))))
    (`failure
     (message "Search for [%s] failed: %s" terms (fstar--string-trim response)))))

(defun fstar-subp--search-query (terms)
  "Prepare a `search' terms for TERMS."
  (make-fstar-subp-query :query "search"
                         :args `(("terms" . ,terms))))

(defun fstar-search (terms)
  "Query F* subprocess for matches against TERMS and display the results.
Interactively, prompt for terms.  Repeating this command hides
the search buffer."
  (interactive '(interactive))
  (fstar-subp--ensure-available #'user-error 'compute)
  (when (eq terms 'interactive)
    (setq terms (fstar--read-string "Search terms%s: " (fstar--fqn-at-point))))
  (setq terms (fstar--string-trim terms))
  (fstar-subp--query (fstar-subp--search-query terms)
                (apply-partially #'fstar-subp--search-continuation terms)))

;;; ;; ;; Jump to definition

(defun fstar--jump-to-definition-continuation (cur-buf display-action info)
  "Jump to position in INFO relative to CUR-BUF.
DISPLAY-ACTION indicates how: nil means in the current window;
`window' means in a side window."
  (-if-let* ((def-loc (and (fstar-lookup-result-p info)
                           (fstar-lookup-result-def-loc info))))
      (with-current-buffer cur-buf
        (fstar--navigate-to def-loc display-action))
    (message "No definition found")))

(defun fstar-jump-to-definition-1 (pos disp)
  "Jump to definition of identifier at POS, if any.
DISP should be nil (display in same window) or
`window' (display in a side window)."
  (let ((cur-buf (current-buffer))
        (buf (fstar-subp--find-any-live-process #'user-error))
        (query (fstar-subp--positional-lookup-query pos '(defined-at))))
    (with-current-buffer buf
      ;; FIXME: `fstar-subp--lookup-wrapper' records the value of the point in the
      ;; current buffer when constructing the callback, and ensures that it
      ;; hasn't changed when the callback is invoked.  This is to ensure that we
      ;; ignore late responses (if F* takes 30 seconds to respond, there's a
      ;; good chance that the user we'll have moved and won't expect a sudden
      ;; jump to a different location).  Unfortunately, here, we call
      ;; fstar-subp--lookup-wrapper in the wrong buffer (instead of calling it in the
      ;; buffer that the user is currently editing, we call it in the parent of
      ;; that buffer, `buf').  Similarly, when the callback is run and the point
      ;; is checked, the check also happens in the parent buffer.  A good fix
      ;; would be to annotate each query with a source buffer, and run its
      ;; callbacks in that buffer.
      (fstar-subp--query query
                    (fstar-subp--lookup-wrapper (point) (apply-partially
                                                    #'fstar--jump-to-definition-continuation
                                                    cur-buf disp))))))

(defun fstar-jump-to-definition ()
  "Jump to definition of identifier at point, if any."
  (interactive)
  (fstar-jump-to-definition-1 (point) nil))

(defun fstar-jump-to-definition-other-window ()
  "Jump to definition of identifier at point, if any."
  (interactive)
  (fstar-jump-to-definition-1 (point) 'window))

(defun fstar-jump-to-definition-other-frame ()
  "Jump to definition of identifier at point, if any."
  (interactive)
  (fstar-jump-to-definition-1 (point) 'frame))

;;; ;; ;; Jump to dependency

(defconst fstar--visit-dependency-buffer-name "*fstar: dependencies*")
(push fstar--visit-dependency-buffer-name fstar--all-temp-buffer-names)

(defun fstar-subp--visit-dependency-insert (source-buf deps)
  "Insert information about DEPS of SOURCE-BUF in current buffer."
  (setq deps (sort deps #'string<))
  (let ((title (format "Dependencies of %s" (buffer-name source-buf))))
    (insert (fstar--propertize-title title) "\n\n"))
  (dolist (fname deps)
    (insert "  ")
    (fstar--insert-link fname 'default nil 'window)
    (insert "\n")))

(defun fstar-subp--visit-dependency-continuation (source-buf status response)
  "Let user jump to one of the dependencies in RESPONSE.
SOURCE-BUF indicates where the query was started from.  STATUS is
the original query's status."
  (-if-let* ((deps (and (eq status 'success)
                        (let-alist response .loaded-dependencies)))
             (help-window-select t))
      (with-help-window fstar--visit-dependency-buffer-name
        (with-current-buffer standard-output
          (fstar-subp--visit-dependency-insert source-buf deps)
          (goto-char (point-min))
          (search-forward "\n\n  " nil t) ;; Find first entry
          (set-marker help-window-point-marker (point))))
    (message "Query `describe-repl' failed")))

(defun fstar-subp--describe-repl-query ()
  "Prepare a `describe-repl' query."
  (make-fstar-subp-query :query "describe-repl" :args nil))

(defun fstar-visit-dependency ()
  "Jump to a file that the current file depends on."
  (interactive)
  (fstar-subp--ensure-available #'user-error 'describe-repl)
  (fstar-subp--query (fstar-subp--describe-repl-query)
                (fstar-subp--pos-check-wrapper (point)
                  (apply-partially #'fstar-subp--visit-dependency-continuation
                                   (current-buffer)))))

;;; ;; ;; Quick-peek

(defun fstar--quick-peek-continuation (info)
  "Show quick help about INFO in inline pop-up."
  (if info
      (let ((segments (list (cl-typecase info
                              (fstar-symbol-info (fstar-symbol-info-sig info))
                              (fstar-option-info (fstar-option-info-sig info))
                              (otherwise (fstar-lookup-result-name info)))
                            (fstar-lookup-result-docstring info))))
        (quick-peek-show (mapconcat #'identity (delq nil segments) "\n\n")
                         (car (with-syntax-table fstar--fqn-at-point-syntax-table
                                (bounds-of-thing-at-point 'symbol)))))
    (message "No information found")))

(defun fstar-quick-peek ()
  "Toggle inline window showing type of identifier at point."
  (interactive)
  (fstar-subp--ensure-available #'user-error 'lookup)
  (when (= (quick-peek-hide) 0)
    (fstar-subp--query (fstar-subp--positional-lookup-query (point)
                    '(type documentation))
                  (fstar-subp--lookup-wrapper (point)
                    #'fstar--quick-peek-continuation))))

;;; ;; ;; Company

(defun fstar-subp--completion-query (prefix &optional context)
  "Prepare a `completions' query from PREFIX in CONTEXT."
  (fstar-assert (not (string-match-p " " prefix)))
  (if (fstar--has-feature 'json-subp)
      (make-fstar-subp-query
       :query "autocomplete"
       :args `(("partial-symbol" . ,prefix)
               ("context" . ,(symbol-name context))))
    (format "#completions %s #" prefix)))

(defconst fstar-subp-company--snippet-re "\\${\\(.+?\\)}")

(defun fstar-subp-company--fontify-snippets-1 (match)
  "Compute prettified rendition of placeholder MATCH."
  (propertize (match-string 1 match) 'face '(bold italic)))

(defun fstar-subp-company--post-process-candidate (candidate)
  "Post-process and return CANDIDATE.
Post-processing includes fontification of snippets — one might
hope to do this in company's pre-render, but pre-render can't
change the length of a candidate."
  (if (string-match-p fstar-subp-company--snippet-re candidate)
      (propertize (replace-regexp-in-string
                   fstar-subp-company--snippet-re
                   #'fstar-subp-company--fontify-snippets-1
                   candidate)
                  'fstar--snippet candidate)
    candidate))

(defun fstar-subp-company-legacy--make-candidate (context line)
  "Extract a candidate from LINE and tag it with CONTEXT."
  (pcase (split-string line " ")
    (`(,match-end ,annot ,candidate . ,_)
     (setq match-end (string-to-number match-end))
     (fstar--set-text-props
      candidate 'fstar--match-end match-end 'fstar--annot annot 'fstar--context context)
     (fstar-subp-company--post-process-candidate candidate))))

(defun fstar-subp-company-json--make-candidate (context record)
  "Extract a candidate from RECORD and tag it with CONTEXT."
  (pcase-let* ((`(,match-end ,annot ,candidate) record))
    (fstar--set-text-props
     candidate 'fstar--match-end match-end 'fstar--annot annot 'fstar--context context)
    (fstar-subp-company--post-process-candidate candidate)))

(defun fstar-subp-company--candidates-continuation
    (context callback additional-completions status response)
  "Handle the results (STATUS, RESPONSE) of an `autocomplete' query.
Return (CALLBACK CANDIDATES).  CONTEXT is propertized onto all candidates.
ADDITIONAL-COMPLETIONS are added to the front of the results list"
  (pcase status
    ((or `failure `interrupted)
     (funcall callback nil))
    (`success
     (save-match-data
       (funcall
        callback
        (append
         additional-completions
         (if (fstar--has-feature 'json-subp)
             (mapcar (apply-partially
                      #'fstar-subp-company-json--make-candidate context)
                     response)
           (delq nil
                 (mapcar (apply-partially
                          #'fstar-subp-company-legacy--make-candidate context)
                         (split-string response "\n"))))))))))

(defconst fstar-subp-company--ns-mod-annots
  '("mod" "ns" "+mod" "+ns" "(mod)" "(ns)" "-mod" "-ns"))

(defun fstar-subp-company--candidate-fqn (candidate context)
  "Compute the fully qualified name of CANDIDATE in CONTEXT."
  (let* ((ns (get-text-property 0 'fstar--annot candidate))
         (snippet (or (get-text-property 0 'fstar--snippet candidate) candidate)))
    (pcase context
      (`code
       (if (member ns (cons "" fstar-subp-company--ns-mod-annots))
           snippet
         (concat ns "." snippet)))
      ((or `set-options `reset-options)
       (replace-regexp-in-string " .*" "" snippet))
      ((or `open `include `module-alias `let-open)
       snippet)
      (_ (error "Unexpected context: %S" context)))))

(defun fstar-subp-company--async-lookup (candidate fields continuation)
  "Pass info FIELDS about CANDIDATE to CONTINUATION.
If CANDIDATE is nil, call CONTINUATION directly with nil.  If F*
is busy, call CONTINUATION directly with symbol `busy'."
  (declare (indent 2))
  (cond
   ((null candidate) ;; `company-mode' sometimes passes us a nil candidate?!
    (funcall continuation nil))
   ((fstar-subp-available-p)
    (fstar-subp--query
     (let* ((context (get-text-property 0 'fstar--context candidate))
            (fqn (fstar-subp-company--candidate-fqn candidate context)))
       (fstar-subp--positionless-lookup-query fqn fields context))
     (fstar-subp--lookup-wrapper nil continuation)))
   (t (funcall continuation 'busy))))

(defun fstar-subp-company--meta-continuation (callback info)
  "Forward type INFO to CALLBACK.
CALLBACK is the company-mode asynchronous meta callback."
  (funcall callback (pcase info
                      (`nil nil)
                      (`busy "F* subprocess unavailable")
                      (_ (fstar-lookup-result--help-ticker info "\\[company-show-doc-buffer]")))))

(defun fstar-subp-company--async-meta (candidate callback)
  "Find type of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-lookup candidate '(type documentation) ;; Needs docs for C-h hint
    (apply-partially #'fstar-subp-company--meta-continuation callback)))

(defun fstar-subp-company--doc-buffer-continuation (callback info)
  "Forward documentation INFO to CALLBACK.
CALLBACK is the company-mode asynchronous doc-buffer callback."
  (funcall callback (when (fstar-lookup-result-p info)
                      (with-current-buffer
                          (get-buffer-create "*company-documentation*")
                        (erase-buffer)
                        (fstar--doc-buffer-populate info)
                        (current-buffer)))))

(defun fstar-subp-company--async-doc-buffer (candidate callback)
  "Find documentation of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-lookup candidate '(type defined-at documentation)
    (apply-partially #'fstar-subp-company--doc-buffer-continuation callback)))

(defun fstar-subp-company--quickhelp-continuation (callback info)
  "Forward documentation INFO to CALLBACK.
CALLBACK is the company-mode asynchronous quickhelp callback."
  (funcall callback (or (and (fstar-lookup-result-p info)
                             (fstar-lookup-result-doc info))
                        "")))

(defun fstar-subp-company--async-quickhelp (candidate callback)
  "Find documentation of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-lookup candidate '(documentation)
    (apply-partially #'fstar-subp-company--quickhelp-continuation callback)))

(defun fstar-subp-company--location-continuation (callback info)
  "Forward type INFO to CALLBACK.
CALLBACK is the company-mode asynchronous meta callback."
  (-if-let* ((def-loc (and (fstar-lookup-result-p info)
                           (fstar-lookup-result-def-loc info))))
      (pcase-let* ((`(,fname ,line ,offset)
                    (cl-etypecase def-loc
                      (string `(,def-loc ,1 ,(point-min)))
                      (fstar-location `(,(fstar-location-remote-filename def-loc)
                                   ,(fstar-location-line-from def-loc)
                                   ,(fstar-location-beg-offset def-loc))))))
        (funcall callback (if (string= fname "<input>")
                              (cons (current-buffer) offset)
                            (cons fname line))))
    (funcall callback nil)))

(defun fstar-subp-company--async-location (candidate callback)
  "Find location of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-lookup candidate '(defined-at)
    (apply-partially #'fstar-subp-company--location-continuation callback)))

(defun fstar-subp-company-reserved-candidates (prefix)
  "Find F* keywords matching PREFIX.
Only exact matches are permitted, so this returns at most one
element, annotated with `fstar--reserved'."
  (let ((case-fold-search nil))
    (when (string-match-p fstar-syntax-reserved-exact-re prefix)
      (list (propertize prefix
                        'fstar--reserved t
                        'meta "Reserved keyword"
                        'doc-buffer nil
                        'quickhelp-string nil
                        'location nil
                        'annotation "kwd")))))

(defvar fstar-subp-company--last-prefix nil)

(defun fstar-subp-company-candidates (prefix context)
  "Compute candidates for PREFIX in CONTEXT.
Briefly tries to get results synchronously to reduce flicker (see
URL `https://github.com/company-mode/company-mode/issues/654'), and
then returns an :async cons, as required by company-mode."
  (setq fstar-subp-company--last-prefix prefix)
  (let ((retv (fstar-subp--query-and-wait
               (fstar-subp--completion-query prefix context) 0.03))
        (extras (fstar-subp-company-reserved-candidates prefix)))
    (pcase retv
      (`(t . (,status ,results))
       (fstar-subp-company--candidates-continuation
        context #'identity extras status results))
      (`(needs-callback . ,_)
       `(:async
         . ,(lambda (cb)
              (setf (cdr retv)
                    (apply-partially
                     #'fstar-subp-company--candidates-continuation
                     context cb extras))))))))

(defun fstar-subp-company--post-completion (candidate)
  "Expand snippet of CANDIDATE, if any."
  (-if-let* ((snippet (get-text-property 0 'fstar--snippet candidate)))
      (fstar--expand-snippet snippet (- (point) (length candidate)) (point))
    (if (and (equal fstar-subp-company--last-prefix candidate)
             (memq 'company-defaults fstar-enabled-modules))
        ;; Insert a newline when pressing RET on a complete candidate (GH-67)
        (call-interactively #'newline))))

(defvar-local fstar-subp-company--completion-context nil
  "Temporary variable to store current completion context.
It's be easier to annotate prefixes with that, but prefixes may
be empty and empty strings can't be annotated.")

(defun fstar-subp-company--prefix ()
  "Compute company prefix at point."
  (when (fstar-subp-available-p)
    (with-syntax-table fstar--fqn-at-point-syntax-table
      (-when-let* ((prefix (company-grab-symbol))
                   (in-code (fstar--in-code-p))
                   (ck (fstar-subp--context-at-point)))
        (let ((always-complete nil))
          (setq prefix (substring-no-properties prefix))
          (when (memq ck '(set-options reset-options))
            (setq prefix (concat "--" prefix))
            (setq always-complete t))
          (setq fstar-subp-company--completion-context ck)
          (if always-complete (cons prefix t) prefix))))))

(defun fstar-subp-company-backend (command &optional arg &rest _rest)
  "Company backend for F*.
Candidates are provided by the F* subprocess.
COMMAND, ARG, REST: see `company-backends'."
  (interactive '(interactive))
  (when (fstar--has-feature 'autocomplete)
    (pcase command
      (`interactive
       (company-begin-backend #'fstar-subp-company-backend))
      (`prefix
       (fstar-subp-company--prefix))
      (`candidates
       (fstar-subp-company-candidates arg fstar-subp-company--completion-context))
      ((guard (and arg (plist-member (text-properties-at 0 arg) command)))
       (get-text-property 0 command arg))
      (`meta
       `(:async . ,(apply-partially #'fstar-subp-company--async-meta arg)))
      (`doc-buffer
       `(:async . ,(apply-partially #'fstar-subp-company--async-doc-buffer arg)))
      (`quickhelp-string
       `(:async . ,(apply-partially #'fstar-subp-company--async-quickhelp arg)))
      (`location
       `(:async . ,(apply-partially #'fstar-subp-company--async-location arg)))
      (`sorted t)
      (`no-cache t)
      (`duplicates nil)
      (`match (get-text-property 0 'fstar--match-end arg))
      (`annotation (get-text-property 0 'fstar--annot arg))
      (`pre-render arg) ;; Preserve fontification of candidates
      (`post-completion (fstar-subp-company--post-completion arg)))))

(defun fstar-setup-company ()
  "Set up Company support."
  (setq-local company-backends
              (cons #'fstar-subp-company-backend company-backends))
  (company-mode))

(defun fstar-teardown-company ()
  "Tear down Company support."
  (kill-local-variable 'company-backends)
  (company-mode -1))

(defun fstar-setup-company-defaults ()
  "Set up Company support."
  (company-quickhelp-local-mode 1)
  (setq-local company-idle-delay 0.01)
  (setq-local company-tooltip-align-annotations t)
  (setq-local company-abort-manual-when-too-short t))

(defun fstar-teardown-company-defaults ()
  "Tear down Company support."
  (company-quickhelp-local-mode -1)
  (kill-local-variable 'company-idle-delay)
  (kill-local-variable 'company-tooltip-align-annotations)
  (kill-local-variable 'company-abort-manual-when-too-short))

;;; ;; ;; Options list

(defconst fstar--list-options-buffer-name "*fstar: options*")
(push fstar--list-options-buffer-name fstar--all-temp-buffer-names)

(defconst fstar--options-true (propertize "true" 'face 'success))
(defconst fstar--options-false (propertize "false" 'face 'error))
(defconst fstar--options-unset (propertize "unset" 'face 'warning))

(defun fstar-subp--option-val-to-string (val)
  "Format VAL for display."
  (cond
   ((eq val t) fstar--options-true)
   ((eq val :json-null) fstar--options-unset)
   ((eq val :json-false) fstar--options-false)
   ((numberp val) (number-to-string val))
   ((stringp val) (propertize (prin1-to-string val) 'face 'font-lock-string-face))
   ((listp val)
    (concat "[" (mapconcat #'fstar-subp--option-val-to-string val " ") "]"))
   (t (warn "Unexpected value %S" val)
      (format "%S" val))))

(defun fstar-subp--is-default (opt-info)
  "Check if OPT-INFO has its val equal to its default."
  (let-alist opt-info
    (equal .value .default)))

(defun fstar-subp--list-options-1 (display-default sp1 sp2 nl opt-info)
  "Insert a row of the option table.
OPT-INFO js a JSON object representing with information about an
F* option; DISPLAY-DEFAULT says whether default values should be
printed.  SP1, SP2, and NL are spacers."
  (let-alist opt-info
    (let ((doc (fstar--lispify-null .documentation))
          (doc-face '(font-lock-comment-face (:height 0.7))))
      (setq doc (or doc ""))
      (setq doc (replace-regexp-in-string " *(default.*)" "" doc t t))
      (setq doc (replace-regexp-in-string " *\n+ *" " " doc t t))
      (setq doc (fstar--string-trim doc))
      (when (eq doc "") (setq doc "(undocumented)"))
      (insert "  " .name sp1 (fstar-subp--option-val-to-string .value)
              (if (not display-default) "\n"
                (concat sp2 (fstar-subp--option-val-to-string .default) "\n"))
              "  " (propertize doc 'face doc-face) nl))))

(defun fstar-subp--list-options-continuation-1 (options display-default title)
  "Print a batch of OPTIONS under TITLE.
With DISPLAY-DEFAULT, also show default values."
  (declare (indent 2))
  (let ((sp1 (concat (propertize " " 'display '(space :align-to 30)) " "))
        (sp2 (concat (propertize " " 'display '(space :align-to 60)) " "))
        (nl (propertize "\n" 'line-spacing 0.4))
        (hdr-face '(bold underline)))
    (insert (fstar--propertize-title title) "\n\n")
    (insert "  " (propertize "Name" 'face hdr-face)
            sp1 (propertize "Value" 'face hdr-face)
            (if (not display-default) nl
              (concat sp2 (propertize "Default value" 'face hdr-face) nl)))
    (dolist (opt-info options)
      (fstar-subp--list-options-1 display-default sp1 sp2 nl opt-info))))

(defun fstar-subp--list-options-continuation (source-buf status response)
  "Let user jump to one of the dependencies in RESPONSE.
SOURCE-BUF indicates where the query was started from.  STATUS is
the original query's status."
  (if (eq status 'success)
      (let-alist response
        (with-help-window fstar--list-options-buffer-name
          (with-current-buffer standard-output
            (let* ((options (cl-sort .options #'string-lessp
                                     :key (lambda (k) (cdr (assoc "name" k)))))
                   (grouped (-group-by #'fstar-subp--is-default options)))
              (fstar-subp--list-options-continuation-1 (cdr (assq nil grouped)) t
                (format "Options set in %s" (buffer-name source-buf)))
              (fstar-subp--list-options-continuation-1 (cdr (assq t grouped)) nil
                "\nUnchanged options")))))
    (message "Query `describe-repl' failed")))

(defun fstar-list-options ()
  "Show information about the current process."
  (interactive)
  (fstar-subp--ensure-available #'user-error 'describe-repl)
  (fstar-subp--query (fstar-subp--describe-repl-query)
                (fstar-subp--pos-check-wrapper (point)
                  (apply-partially #'fstar-subp--list-options-continuation
                                   (current-buffer)))))

;;; ;; ;; Busy spinner

(defvar-local fstar--spin-timer nil)

(defvar-local fstar--spin-counter 0)

(defcustom fstar-spin-theme "✪⍟"
  "Which theme to use in indicating that F* is busy."
  :type '(choice (const "✪⍟")
                 (const #("✪✪"
                          0 1 (composition ((1 . "\t✪\t")))
                          1 2 (face (:inverse-video t) composition ((1 . "\t✪\t")))))
                 (const "✪●")
                 (const "✪○")
                 (const "✪❂")
                 (const "✪🌠")
                 (const "★☆")
                 (const "★✩✭✮")
                 (const "★🟀🟄🟉✶🟎✹")
                 (const "★🟃🟇🟍✵🟑🟔")
                 (const "★🟃🟀🟇🟄🟍✶✵🟎🟔🟓")
                 (const #("★★"
                          0 1 (display ((raise 0.2) (height 0.75)))
                          1 2 (display ((raise 0) (height 0.75)))))
                 (string :tag "Custom string")))

(defun fstar--spin-cancel ()
  "Cancel spin timer."
  (when fstar--spin-timer
    (cancel-timer fstar--spin-timer)
    (setq-local fstar--spin-timer nil)))

(defvar fstar--spin-modename "F✪"
  "String build by the snippet to replace the mode name.")
(put 'fstar--spin-modename 'risky-local-variable t)

(defun fstar--spin-tick (buffer timer)
  "Update fstar-mode's mode-line indicator in BUFFER.
TIMER is the timer that caused this event to fire."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (and fstar--spin-timer (fstar-subp--busy-p))
            (setq fstar--spin-counter (mod (1+ fstar--spin-counter) (length fstar-spin-theme)))
          (setq fstar--spin-counter 0))
        (let ((icon (substring fstar-spin-theme fstar--spin-counter (1+ fstar--spin-counter))))
          (setq icon (compose-string icon 0 1 (format "\t%c\t" (aref icon 0))))
          (setq-local fstar--spin-modename `("F" ,icon))
          (force-mode-line-update)))
    (cancel-timer timer)))

(defun fstar-setup-spinner ()
  "Enable dynamic F* icon."
  (let* ((timer nil)
         (buf (current-buffer))
         (ticker (lambda () (fstar--spin-tick buf timer))))
    (setq timer (run-with-timer 0 0.5 ticker))
    (setq-local fstar--spin-timer timer)))

(defun fstar-teardown-spinner ()
  "Disable dynamic F* icon."
  (fstar--spin-cancel))

;;; ;; ;; Notifications

(defvar fstar--emacs-has-focus t
  "Boolean indicating whether Emacs is currently has focus.
Notifications are only displayed if it doesn't.")

(defun fstar--notify-overlay-processed (_overlay status _response)
  "Possibly show a notification about STATUS."
  (unless (or fstar--emacs-has-focus (fstar-subp-tracking-overlays 'pending))
    (let ((title (let ((fname (file-name-nondirectory (buffer-file-name))))
                   (format "Prover ready (%s)" fname)))
          (body (pcase status
                  (`interrupted "Verification interrupted")
                  (`success "Verification completed successfully")
                  (`failure "Verification failed")))
          (icon (expand-file-name "etc/fstar.png" fstar--directory)))
      (cond
       ((and (featurep 'dbusbind) (fboundp 'notifications-notify))
        (notifications-notify :app-icon icon :title title :body body))
       ((fboundp 'w32-notification-notify)
        (w32-notification-notify :title title :body body))
       ((and (require 'alert nil t) (fboundp 'alert))
        (alert body :icon icon :title title))))))

(defun fstar--notify-focus-in ()
  "Handle a focus-in event."
  (setq fstar--emacs-has-focus t))

(defun fstar--notify-focus-out ()
  "Handle a focus-out event."
  (setq fstar--emacs-has-focus nil))

(defun fstar-setup-notifications ()
  "Enable proof completion notifications."
  (add-hook 'focus-in-hook #'fstar--notify-focus-in)
  (add-hook 'focus-out-hook #'fstar--notify-focus-out)
  (add-hook 'fstar-subp-overlay-processed-hook #'fstar--notify-overlay-processed nil t))

(defun fstar-teardown-notifications ()
  "Disable proof completion notifications."
  (remove-hook 'fstar-subp-overlay-processed-hook #'fstar--notify-overlay-processed t))

(defun fstar-unload-notifications ()
  "Remove leftover hooks from proof completion notifications."
  (remove-hook 'focus-in-hook #'fstar--notify-focus-in)
  (remove-hook 'focus-out-hook #'fstar--notify-focus-out))

;;; ;; ;; Tactics

(cl-defstruct fstar-proof-state
  label location urgency goals smt-goals)

(defconst fstar--goals-buffer-name "*fstar: goals*")
(push fstar--goals-buffer-name fstar--all-temp-buffer-names)

(defconst fstar-tactics--half-line-prefix
  (propertize " " 'display '(space :width 1.5)))

(defconst fstar-tactics--goal-separator
  (propertize (make-string 80 ?-) 'display '(space :align-to right)))

(defface fstar-proof-state-separator-face
  '((t :inherit highlight :height 0.1))
  "Face applied to the goal line in proof states."
  :group 'fstar-tactics)

(defface fstar-proof-state-header-face
  '((t :weight bold))
  "Face applied to proof-state headers in proof states window."
  :group 'fstar-tactics)

(defface fstar-proof-state-header-timestamp-face
  '((t :inherit font-lock-comment-face))
  "Face applied to proof-state headers in proof states window."
  :group 'fstar-tactics)

(defface fstar-goal-header-face
  '((t :weight demibold))
  "Face applied to goal headers in proof states."
  :group 'fstar-tactics)

(defface fstar-hypothesis-name-face
  '((t :inherit (font-lock-variable-name-face bold)))
  "Face applied to hypothesis names in proof states."
  :group 'fstar-tactics)

(defface fstar-hypothesis-face
  '((t))
  "Face applied to hypotheses in proof states."
  :group 'fstar-tactics)

(defface fstar-goal-line-face
  '((((supports :strike-through t)) :strike-through t :height 0.5)
    (t :underline t))
  "Face applied to the goal line in proof states."
  :group 'fstar-tactics)

(defface fstar-goal-type-face
  '((t))
  "Face applied to the goal's type in proof states."
  :group 'fstar-tactics)

(defface fstar-goal-witness-face
  '((t :height 0.75 :inherit font-lock-comment-face))
  "Face applied to the goal's witness in proof states."
  :group 'fstar-tactics)

(defun fstar-tactics--insert-hyp-group (names type)
  "Insert NAMES: TYPE into current buffer."
  (while names
    (fstar--insert-with-face 'fstar-hypothesis-name-face (pop names))
    (insert (if names " " ": ")))
  (let* ((indent (- (point) (point-at-bol)))
         (wrap (concat line-prefix (make-string indent ?\s))))
    (fstar--insert-ln-with-face 'fstar-hypothesis-face
        (propertize (fstar-highlight-string type) 'wrap-prefix wrap))))

(defun fstar-tactics--cons-of-hyp (hyp)
  "Convert HYP into a (NAMES . TYPE) cons."
  (let-alist hyp (cons .name .type)))

(defun fstar-tactics--group-hyps (hyps)
  "Convert HYPS into a list of (NAMES . TYPE) conses.
Consecutive hypothesis with equal types are gathered in a single
cell."
  (let ((gathered nil)
        (prev-type nil))
    (while hyps
      (pcase-let ((`(,name . ,type) (fstar-tactics--cons-of-hyp (pop hyps))))
        (if (equal type prev-type)
            (push name (caar gathered))
          (push (cons (list name) type) gathered))
        (setq prev-type type)))
    (nreverse (mapcar (lambda (p) (cl-callf nreverse (car p)) p) gathered))))

(defun fstar-tactics--insert-goal (goal)
  "Insert GOAL into current buffer."
  (let-alist goal
    (pcase-dolist (`(,names . ,type) (fstar-tactics--group-hyps .hyps))
      (fstar-tactics--insert-hyp-group names type))
    (fstar--insert-with-face 'fstar-goal-line-face "%s\n" fstar-tactics--goal-separator)
    (fstar--insert-ln-with-face 'fstar-goal-type-face (fstar-highlight-string .goal.type))
    (fstar--insert-ln-with-face 'fstar-goal-witness-face (fstar-highlight-string .goal.witness))))

(defun fstar-tactics--insert-goals (goals kind)
  "Insert GOALS of type KIND (“Goal” or “SMT goal”) into current buffer."
  (let ((goal-id 0)
        (ngoals (length goals)))
    (dolist (goal goals)
      (cl-incf goal-id)
      (fstar--insert-with-face 'fstar-goal-header-face
          (propertize "%s %d/%d%s%s"
                      'line-prefix fstar-tactics--half-line-prefix
                      'wrap-prefix fstar-tactics--half-line-prefix)
        kind goal-id ngoals
        (let ((label (let-alist goal .goal.label)))
          (if (member label '(nil "")) "" (format " (%s)" label)))
        (propertize "\n" 'line-spacing 0.2))
      (fstar-tactics--insert-goal goal)
      (insert "\n"))))

(defun fstar-tactics--insert-proof-state (ps)
  "Dump proof state PS into current buffer."
  (unless (bobp)
    (fstar--insert-with-face 'fstar-proof-state-separator-face
        (propertize "\n" 'line-prefix "" 'line-height t))
    (insert "\n"))
  (fstar--insert-with-face 'fstar-proof-state-header-face
      (propertize (or (fstar-proof-state-label ps) "…")
                  'line-prefix "" 'wrap-prefix "" 'fstar--proof-state ps))
  (-when-let* ((loc (fstar-proof-state-location ps))
               (txt (fstar--loc-to-string loc))
               (link-text (fstar--truncate-left txt 40)))
    (insert " @ ")
    (fstar--insert-link loc 'link link-text 'window))
  (let ((timestamp (current-time-string)))
    (insert " " (fstar--specified-space-to-align-right timestamp 1))
    (fstar--insert-with-face 'fstar-proof-state-header-timestamp-face timestamp))
  (insert (propertize "\n" 'line-spacing 0.2))
  (fstar-tactics--insert-goals (fstar-proof-state-goals ps) "Goal")
  (fstar-tactics--insert-goals (fstar-proof-state-smt-goals ps) "SMT goal"))

(defun fstar-tactics--proof-state-at-point ()
  "Read the proof state from the current point."
  (get-text-property (point) 'fstar--proof-state))

(defun fstar-tactics-display-source-location ()
  "Highlight source of goal at point."
  (-when-let* ((ps (fstar-tactics--proof-state-at-point))
               (loc (fstar-proof-state-location ps)))
    (fstar--navigate-to-1 loc 'window nil)))

(defun fstar-tactics--next-proof-state (&optional n)
  "Go forward N goals (default: 1)."
  (interactive "^p")
  (setq n (or n 1))
  (if (< n 0)
      (fstar-tactics--previous-proof-state (- n))
    (dotimes (_ n)
      (goto-char (point-at-eol))
      (let ((next (next-single-char-property-change (point) 'fstar--proof-state)))
        (unless (eq next (point-max)) (goto-char next)))
      (goto-char (point-at-bol)))
    (fstar-tactics-display-source-location)
    (recenter 0)))

(defun fstar-tactics--previous-proof-state (&optional n)
  "Go back N goals (default: 1)."
  (interactive "^p")
  (setq n (or n 1))
  (if (< n 0)
      (fstar-tactics--next-proof-state (- n))
    (dotimes (_ n)
      (goto-char (point-at-eol))
      (dotimes (_ 3)
        (goto-char (previous-single-char-property-change (point) 'fstar--proof-state))))
    (goto-char (point-at-bol))
    (fstar-tactics-display-source-location)
    (recenter 0)))

(defvar fstar-tactics--goals-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap scroll-up-command] #'fstar-tactics--next-proof-state)
    (define-key map [remap scroll-down-command] #'fstar-tactics--previous-proof-state)
    map))

(define-derived-mode fstar-tactics--goals-mode help-mode "F✪ Goals"
  "Major mode for viewing F* goals.
Commands:
\\{fstar-tactics--goals-mode-map}"
  (visual-line-mode)
  (setq line-prefix "   ")
  (setq wrap-prefix line-prefix))

(defun fstar-tactics--goals-buffer ()
  "Create or return F*-mode's goal buffer.
This function exists to work around the fact that
`with-help-window' clears the buffer."
  (or (get-buffer fstar--goals-buffer-name)
      (with-current-buffer (temp-buffer-window-setup fstar--goals-buffer-name)
        (fstar-tactics--goals-mode)
        (current-buffer))))

(defmacro fstar-tactics--with-goals-buffer (&rest body)
  "Run BODY in F*'s goals buffer"
  (declare (debug t)
           (indent 0))
  `(with-current-buffer (fstar-tactics--goals-buffer)
     (let ((inhibit-read-only t))
       ,@body)))

(defun fstar-subp-json--parse-proof-state (json)
  "Convert JSON proof-state an fstar-mode proof state."
  (let-alist json
    (make-fstar-proof-state
     :label (if (equal .label "") nil .label)
     :location (and .location (fstar-subp-json--parse-location .location))
     :urgency (or .urgency 1)
     :goals .goals
     :smt-goals .smt-goals)))

(defun fstar-tactics--display-proof-state (proof-state)
  "Display PROOF-STATE in a separate *goals* buffer."
  (let ((help-window-select nil)
        (ps (fstar-subp-json--parse-proof-state proof-state)))
    (fstar-tactics--with-goals-buffer
      (goto-char (point-max))
      (save-excursion
        (fstar-tactics--insert-proof-state ps))
      (unless (bobp) (forward-line 2))
      (set-marker help-window-point-marker (point))
      (if (> (fstar-proof-state-urgency ps) 0)
          (let ((window (temp-buffer-window-show (current-buffer))))
                (help-window-setup window)
                (with-selected-window window
                  (recenter 0)))))))

;;; ;; Starting the F* subprocess

(defun fstar--raise-file-not-found (path prog-name var-name)
  "Use PROG-NAME and VAR-NAME to complain about PATH not being found."
  (user-error "%s (“%s”) not found%s" prog-name path
              (if var-name (format "; please adjust `%s'" var-name) "")))

(defun fstar--check-executable (path prog-name var-name)
  "Check if PATH exists and is executable.
PROG-NAME and VAR-NAME are used in error messages."
  (unless (and path (file-exists-p path))
    (fstar--raise-file-not-found path prog-name var-name))
  (unless (file-executable-p path)
    (user-error "%s (“%s”) not executable%s" prog-name path
                (if var-name (format "; please check `%s'" var-name) "")))
  path)

(defun fstar-find-executable (prog prog-name &optional var-name local-only)
  "Compute the absolute path to PROG.
Check that the binary exists and is executable; if not, raise an
error referring to PROG as PROG-NAME and VAR-NAME.  This function
looks for a remote binary when the current buffer is a Tramp
file, unless LOCAL-ONLY is set (but the return value never
includes a Tramp prefix)."
  (if (or local-only (fstar--local-p))
      (fstar--check-executable (or (executable-find prog) prog) prog-name var-name)
    (let ((prog-name (concat "Remote " prog-name))
          (tramp-vect (tramp-dissect-file-name buffer-file-name)))
      (if (file-name-absolute-p prog)
          (let ((remote-prog (concat (fstar--remote-p) prog)))
            (and (fstar--check-executable remote-prog prog-name var-name) prog))
        (unless (tramp-find-executable tramp-vect prog nil)
          (fstar--raise-file-not-found prog prog-name var-name))
        ;; Return PROG directly, because `tramp-find-executable' prepends
        ;; PROG with “\” when it's in $PATH, which confuses `process-file'.
        prog))))

(defun fstar-subp-buffer-killed ()
  "Kill F* process associated to current buffer."
  (-when-let* ((proc (get-buffer-process (current-buffer))))
    (run-with-timer 0 nil #'fstar-subp-kill-proc proc)))

(defun fstar-subp-make-buffer ()
  "Create a buffer for the F* subprocess."
  (let ((vernum fstar--vernum)
        (features fstar--features))
    (with-current-buffer (generate-new-buffer
                          (format " *F* interactive for %s*" (buffer-name)))
      (add-hook 'kill-buffer-hook #'fstar-subp-buffer-killed t t)
      (setq fstar--vernum vernum fstar--features features)
      (buffer-disable-undo)
      (current-buffer))))

(defun fstar-subp-prover-args-safe-p (args)
  "Check whether ARGS is a known-safe value for `fstar-subp-prover-args'."
  (equal args 'fstar-subp-prover-args-for-compiler-hacking))

(defcustom fstar-subp-prover-args nil
  "Arguments to pass to F* in interactive mode.

If set to a string, that string is considered to be a single
argument to pass to F*.  If set to a list of strings, each element
of the list is passed to F*.  If set to a function, that function
is called in the current buffer without arguments, and expected
to produce a string or a list of strings.

Some examples (see below about `…'):

- (setq fstar-subp-prover-args \"--ab\") results in F* being
called as ‘fstar.exe … --ab …’.

- (setq fstar-subp-prover-args \\='(\"--ab\" \"--cd\")) results in
F* being called as ‘fstar.exe … --ab --cd …’.

- (setq fstar-subp-prover-args (lambda () \\='(\"--ab\" \"--cd\")))
results in F* being called as ‘fstar.exe … --ab --cd …’.

In addition to these flags, `fstar-mode' always includes (as
indicated above by the first `…') both \\='--smt <path-to-z3>\\='
and one of \\='--ide\\=' and \\='--in\\=', and any flags computed
from `fstar-subp-prover-additional-args' (as indicated above by
the second `…').

To debug unexpected behaviors with this variable, try
evaluating (fstar-subp-get-prover-args).  Note that passing
multiple arguments as one string will not work: you should use
\\='(\"--aa\" \"--bb\"), not \"--aa --bb\"."
  :group 'fstar
  :type '(repeat string)
  :safe #'fstar-subp-prover-args-safe-p)

(defcustom fstar-subp-prover-additional-args nil
  "Additional arguments to pass to F* in interactive mode.

See `fstar-subp-prover-args' for documentation about the format
of this variable.  Flags derived from this one are added after
flags derived from `fstar-subp-prover-args'.

This is mostly useful when working on a project that requires a
specific value of `fstar-subp-prover-args' (typically a function)."
  :group 'fstar
  :type '(repeat string))

(defun fstar-subp-find-fstar ()
  "Find path to F* executable."
  (fstar-find-executable fstar-executable "F*" 'fstar-executable))

(defun fstar-subp-find-smt-solver ()
  "Find path to SMT solver executable."
  (fstar-find-executable fstar-smt-executable "SMT solver" 'fstar-smt-executable))

(defun fstar-subp--parse-prover-args-1 (args var-name)
  "Parse value of ARGS into a list of strings.
Complain about VAR-NAME if the final value isn't a string or a
list of strings."
  (let ((args (fstar--resolve-fn-value args)))
    (when (stringp args)
      (setq args (list args)))
    (unless (and (listp args) (cl-every #'stringp args))
      (user-error "Interpreting `%s' \
led to invalid value [%s]" var-name args))
    args))

(defmacro fstar-subp--parse-prover-args (argsv)
  "Like `fstar-subp--parse-prover-args-1' on ARGSV, but infer VAR-NAME."
  `(fstar-subp--parse-prover-args-1 ,argsv ',argsv))

(defun fstar-subp-get-prover-args (&optional no-ide)
  "Compute F*'s arguments.
Function is public to make it easier to debug
`fstar-subp-prover-args' and
`fstar-subp-prover-additional-args'.
Non-nil NO-IDE means don't include `--ide' and `--in'."
  (let ((smt-path (fstar--maybe-cygpath (fstar-subp-find-smt-solver)))
        (ide-flag (if no-ide nil
                    (if (fstar--has-feature 'json-subp) '("--ide") '("--in"))))
        (usr-args (append
                   (fstar-subp--parse-prover-args fstar-subp-prover-args)
                   (fstar-subp--parse-prover-args fstar-subp-prover-additional-args))))
    `(,(fstar-subp--buffer-file-name) ,@ide-flag "--smt" ,smt-path ,@usr-args)))

(defun fstar-subp--prover-includes-for-compiler-hacking ()
  "Compute a list of folders to include for hacking on the F* compiler."
  (-if-let* ((fname (buffer-file-name))
             (default-directory (locate-dominating-file fname "_tags")))
      (let ((exclude-list '("." ".." "VS" "tests" "tools" "boot_fstis"
                            "ocaml-output" "u_ocaml-output" "u_boot_fsts"))
            (src-dir (expand-file-name "src" default-directory))
            (include-dirs nil))
        (push (expand-file-name "ulib") include-dirs)
        (dolist (dir (directory-files src-dir nil))
          (unless (member dir exclude-list)
            (let ((fulldir (expand-file-name dir src-dir)))
              (when (file-directory-p fulldir)
                (push fulldir include-dirs)))))
        (nreverse include-dirs))
    (user-error (concat "Couldn't find _tags file while trying to "
                        " set up F*-mode for compiler hacking."))))

(defun fstar-subp-prover-args-for-compiler-hacking ()
  "Compute arguments suitable for hacking on the F* compiler."
  `("--eager_inference" "--lax" "--MLish" "--warn_error" "-272"
    ,@(-mapcat (lambda (dir) `("--include" ,dir))
               (fstar-subp--prover-includes-for-compiler-hacking))))

(defvar fstar-subp--default-directory nil
  "Directory in which to start F*.

If nil, use `default-directory'.  This is useful to properly
interpret the paths on the command line when Emacs is started
with `-f fstar-debug-invocation'.")

;;;###autoload
(defun fstar-debug-invocation ()
  "Compute F*'s arguments from `argv' and visit the corresponding file.

This is useful to quickly debug a failing invocation: just prefix
the whole command line with `emacs -f fstar-debug-invocation'."
  (pcase-let ((fname (car (last argv)))
              (`(,executable . ,args) (butlast argv))
              (fstar-exec-re "fstar\\.\\(exe\\|byte\\|native\\)?\\'")
              (err-header (format "Unsupported invocation: %S." argv)))
    (unless fname
      (user-error "%s
Last argument must be a file name, not %S" err-header fname))
    (unless (and executable (string-match-p fstar-exec-re executable))
      (user-error "%s
First argument must be an F* executable, not %S" err-header executable))
    (with-current-buffer (find-file-existing fname)
      (setq-local fstar-subp-prover-args args)
      (setq-local fstar-subp--default-directory command-line-default-directory)
      (message "\
F* binary: %S
F* arguments: %S
Current file: %S" fstar-executable fstar-subp-prover-args buffer-file-name)
      (setq argv nil))))

(defun fstar-subp--buffer-file-name ()
  "Find name of current buffer, as sent to F*."
  (if (fstar--remote-p)
      (tramp-file-name-localname
       (tramp-dissect-file-name buffer-file-name))
    (fstar--maybe-cygpath buffer-file-name)))

(defconst fstar-subp--process-name "F* interactive")

(defun fstar-subp--start-process (buf prog args)
  "Start an F* subprocess PROG in BUF with ARGS."
  (let ((default-directory (or fstar-subp--default-directory default-directory)))
    (apply #'start-file-process fstar-subp--process-name buf prog args)))

(defun fstar-subp--wait-for-features-list (proc)
  "Busy-wait until the first protocol-info message from PROC."
  (let ((start-time (current-time)))
    (while (not (memq 'push fstar--features))
      (accept-process-output proc 0.01 nil 1)
      (unless (process-live-p proc)
        (error "F* exited instantaneously (check *Messages* for more info; \
this usually stems from mistakes in arguments passed to F*).
Could it be a typo in `fstar-subp-prover-args' or \
`fstar-subp-prover-additional-args'?")))
    (fstar-log 'info "[%.2fms] Feature list received"
          (* 1000 (float-time (time-since start-time))))))

(defun fstar-subp-start ()
  "Start an F* subprocess attached to the current buffer, if none exist."
  (interactive)
  (unless (and buffer-file-name (file-exists-p buffer-file-name))
    (user-error "Can't start F* subprocess without a backing file (save this buffer first)"))
  (unless (process-live-p fstar-subp--process)
    (let ((f*-abs (fstar-subp-find-fstar)))
      (fstar--init-compatibility-layer f*-abs)
      (let* ((buf (fstar-subp-make-buffer))
             (process-connection-type nil)
             (tramp-process-connection-type nil)
             (args (fstar-subp-get-prover-args))
             (proc (fstar-subp--start-process buf f*-abs args)))
        (fstar-log 'info "")
        (fstar-log 'info "Started F* interactive: %S" (cons f*-abs args))
        (set-process-query-on-exit-flag proc nil)
        (set-process-filter proc #'fstar-subp-filter)
        (set-process-sentinel proc #'fstar-subp-sentinel)
        (set-process-coding-system proc 'utf-8 'utf-8)
        (process-put proc 'fstar-subp-source-buffer (current-buffer))
        (setq fstar-subp--process proc)
        (setq fstar-subp--prover-args args)
        (setq fstar-subp--continuations (make-hash-table :test 'equal))
        (when (fstar--has-feature 'json-subp)
          (fstar-subp--wait-for-features-list proc))))))

;;; Running F* on the CLI

(defconst fstar--cli-verification-buffer-name "*fstar: CLI verification of %S")
(push fstar--cli-verification-buffer-name fstar--all-temp-buffer-names)

(defun fstar-cli-verify ()
  "Send the whole buffer to a fresh instance of F* running in CLI mode.
This is useful to spot discrepancies between the CLI and IDE frontends."
  (interactive)
  (let* ((f* (fstar-subp-find-fstar))
         (args (fstar-subp-get-prover-args t))
         (cmd (mapconcat #'shell-quote-argument (cons f* args) " "))
         (buf-name (buffer-file-name))
         (name-fn (lambda (_) (format fstar--cli-verification-buffer-name buf-name)))
         (compilation-buffer (compilation-start cmd t name-fn)))
    (with-current-buffer compilation-buffer
      (defvar compilation-error-regexp-alist)
      (setq-local compilation-error-regexp-alist
                  (flycheck-checker-compilation-error-regexp-alist 'fstar)))))

;;; ;; Keybindings

(defconst fstar-subp-keybindings-table
  '(("C-c C-n"        "C-S-n" fstar-subp-advance-next)
    ("C-c C-u"        "C-S-p" fstar-subp-retract-last)
    ("C-c C-p"        "C-S-p" fstar-subp-retract-last)
    ("C-c RET"        "C-S-i" fstar-subp-advance-or-retract-to-point)
    ("C-c <C-return>" "C-S-i" fstar-subp-advance-or-retract-to-point)
    ("C-c C-l"        "C-S-l" fstar-subp-advance-or-retract-to-point-lax)
    ("C-c C-."        "C-S-." fstar-subp-goto-beginning-of-unprocessed-region)
    ("C-c C-b"        "C-S-b" fstar-subp-advance-to-point-max-lax)
    ("C-c C-r"        "C-S-r" fstar-subp-reload-to-point)
    ("C-c C-x"        "C-M-c" fstar-subp-kill-one-or-many)
    ("C-c C-c"        "C-M-S-c" fstar-subp-interrupt))
  "Proof-General and Atom bindings table.")

(defun fstar-subp-refresh-keybinding (bind target unbind)
  "Bind BIND to TARGET, and unbind UNBIND."
  (define-key fstar-mode-map (kbd bind) target)
  (define-key fstar-mode-map (kbd unbind) nil))

(defun fstar-subp-refresh-keybindings (style)
  "Adjust keybindings to match STYLE."
  (cl-loop for (pg atom target) in fstar-subp-keybindings-table
           do (pcase style
                (`pg   (fstar-subp-refresh-keybinding pg target atom))
                (`atom (fstar-subp-refresh-keybinding atom target pg))
                (other (user-error "Invalid keybinding style: %S" other)))))

(defun fstar-subp-set-keybinding-style (var style)
  "Set VAR to STYLE and update keybindings."
  (set-default var style)
  (fstar-subp-refresh-keybindings style))

(defcustom fstar-interactive-keybinding-style 'pg
  "Which style of bindings to use in F* interactive mode."
  :group 'fstar-interactive
  :set #'fstar-subp-set-keybinding-style
  :type '(choice (const :tag "Proof-General style bindings" pg)
                 (const :tag "Atom-style bindings" atom)))

;;; ;; Main fstar-subp entry point

(defun fstar-setup-interactive ()
  "Setup interactive F* mode."
  (fstar-subp-refresh-keybindings fstar-interactive-keybinding-style)
  (setq-local help-at-pt-display-when-idle t)
  (setq-local help-at-pt-timer-delay 0.2)
  (help-at-pt-cancel-timer)
  (help-at-pt-set-timer))

(defun fstar-teardown-interactive ()
  "Cleanup F* interactive mode."
  (help-at-pt-cancel-timer)
  (fstar-subp-kill))


;;; Menu

(defun fstar-customize ()
  "Open `fstar-mode''s customization menu."
  (interactive)
  (customize-group 'fstar))

(easy-menu-define fstar-mode-menu fstar-mode-map
  ;; Putting the menu in `fstar-mode-map' (a local map) ensures that it appears after
  ;; all global menus (File, Edit, …)
  #("F✪'s main menu" 1 2 (composition ((1 . "\t✪\t"))))
  '(#("F✪" 1 2 (composition ((1 . "\t✪\t"))))
    ("Navigation"
     ["Visit interface file"
      fstar--visit-interface :visible (not (fstar--visiting-interface-p))]
     ["Visit implementation file"
      fstar--visit-implementation :visible (fstar--visiting-interface-p)]
     ["Visit a dependency of this file"
      fstar-visit-dependency :visible (fstar-subp-available-p)]
     ["Show an outline of this file"
      fstar-outline]
     ["Hide/show lines annotated with (**)"
      fstar-selective-display-mode]
     [#("Close all temporary F✪ windows" 21 22 (composition ((1 . "\t✪\t"))))
      fstar-quit-windows])
    (#("F✪ subprocess" 1 2 (composition ((1 . "\t✪\t"))))
     [#("Start F✪ subprocess" 7 8 (composition ((1 . "\t✪\t"))))
      fstar-subp-start (not (process-live-p fstar-subp--process))]
     ["Interrupt Z3"
      fstar-subp-kill-z3 (fstar-subp--busy-p)]
     [#("Kill F✪ subprocess" 6 7 (composition ((1 . "\t✪\t"))))
      fstar-subp-kill-one-or-many (process-live-p fstar-subp--process)])
    ("Proof state"
     ["Typecheck next definition"
      fstar-subp-advance-next]
     ["Typecheck next definition (lax)"
      fstar-subp-advance-next-lax]
     ["Retract last definition"
      fstar-subp-retract-last]
     ["Typecheck everything up to point"
      fstar-subp-advance-or-retract-to-point]
     ["Typecheck everything up to point (lax)"
      fstar-subp-advance-or-retract-to-point-lax]
     ["Typecheck whole buffer (lax)"
      fstar-subp-advance-to-point-max-lax]
     ["Reload dependencies and re-typecheck up to point"
      fstar-subp-reload-to-point]
     [#("Show current value of all F✪ options" 27 28 (composition ((1 . "\t✪\t"))))
      fstar-list-options (fstar-subp-available-p)])
    ("Interactive queries"
     ["Evaluate an expression"
      fstar-eval (fstar-subp-available-p)]
     ["Evaluate an expression (with custom reduction rules)"
      fstar-eval-custom (fstar-subp-available-p)]
     ["Show type and docs of an identifier"
      fstar-doc (fstar-subp-available-p)]
     ["Show definition of an identifier"
      fstar-print (fstar-subp-available-p)]
     ["Search for functions or theorems"
      fstar-search (fstar-subp-available-p)]
     ["Quick peek"
      fstar-quick-peek (fstar-subp-available-p)])
    (#("Literate F✪" 10 11 (composition ((1 . "\t✪\t"))))
     ["Switch to reStructuredText mode"
      fstar-literate-fst2rst]
     ["Display an HTML preview of the current buffer."
      fstar-literate-preview])
    ("Utilities"
     ["Verify current file on the command line"
      fstar-cli-verify]
     ["Copy error message at point"
      fstar-copy-help-at-point (fstar--check-help-at-point)])
    ["Configuration" fstar-customize]))

;;; Tool bar

(defun fstar-tool-bar--add-item (command icon map)
  "Add an ICON running COMMAND to MAP."
  (tool-bar-local-item-from-menu
   command nil map fstar-mode-map
   :vert-only t :fstar-icon icon))

(defconst fstar-tool-bar--icons-directory
  (let ((shade (pcase frame-background-mode (`dark 'light) (_ 'dark))))
    (expand-file-name (format "etc/icons/%S" shade) fstar--directory)))

(defun fstar-tool-bar--cleanup-binding (binding)
  "Recompute :image spec in toolbar entry BINDING."
  (pcase binding
    (`(,key menu-item ,doc ,cmd . ,props)
     (-when-let* ((img (plist-get props :fstar-icon)))
       (let ((specs nil))
         (dolist (type '(xpm png svg))
           (let* ((fname (format "%s.%S" img type))
                  (fpath (expand-file-name fname fstar-tool-bar--icons-directory)))
             (push `(:type ,type :file ,fpath :scale 1.0) specs)))
         (setq props (plist-put props :image `(find-image '(,@specs))))))
     `(,key menu-item ,doc ,cmd . ,props))
    (_ binding)))

(defun fstar-tool-bar--cleanup-map (map)
  "Replace image paths in MAP.
This is a hacky way to work around the fact that
`tool-bar-local-item-from-menu' doesn't include `png' files in
its `find-image' forms."
  (pcase map
    (`(keymap . ,bindings)
     `(keymap . ,(mapcar #'fstar-tool-bar--cleanup-binding bindings)))
    (_ map)))

(defvar fstar-tool-bar--map
  (let ((map (make-sparse-keymap)))
    (cl-flet ((add-item (cmd img) (fstar-tool-bar--add-item cmd img map)))
      (add-item 'fstar-subp-advance-or-retract-to-point "goto-point")
      (add-item 'fstar-subp-advance-or-retract-to-point-lax "goto-point-lax")
      (add-item 'fstar-subp-retract-last "previous")
      (define-key-after map [basic-actions-sep] '(menu-item "--"))
      (add-item 'fstar-subp-advance-next "next")
      (add-item 'fstar-subp-advance-next-lax "next-lax")
      (add-item 'fstar-subp-advance-to-point-max-lax "goto-end-lax")
      (add-item 'fstar-subp-reload-to-point "reload")
      (define-key-after map [views-sep] '(menu-item "--"))
      (add-item 'fstar-eval "eval")
      (add-item 'fstar-quick-peek "quick-peek")
      (add-item 'fstar-doc "lookup-documentation")
      (add-item 'fstar-print "lookup-definition")
      (add-item 'fstar-search "search")
      (add-item 'fstar-copy-help-at-point "copy-error-message")
      (add-item 'fstar-list-options "list-options")
      (define-key-after map [actions-sep] '(menu-item "--"))
      (add-item 'fstar-outline "outline")
      (add-item 'fstar-selective-display-mode "ghost")
      (add-item 'fstar--visit-interface "switch-to-interface")
      (add-item 'fstar--visit-implementation "switch-to-implementation")
      (define-key-after map [queries-sep] '(menu-item "--"))
      (add-item 'fstar-literate-fst2rst "switch-to-rst")
      (add-item 'fstar-literate-preview "preview-rst")
      (define-key-after map [literate-sep] '(menu-item "--"))
      (add-item 'fstar-quit-windows "quit-windows")
      (add-item 'fstar-subp-kill-one-or-many "stop")
      (add-item 'fstar-cli-verify "cli-verify")
      (define-key-after map `[process-management-sep] '(menu-item "--"))
      (add-item 'fstar-customize "settings"))
    (fstar-tool-bar--cleanup-map map)))

(defun fstar-setup-tool-bar ()
  "Display the F* toolbar."
  (setq-local tool-bar-map fstar-tool-bar--map))

(defun fstar-teardown-tool-bar ()
  "Hide the F* toolbar."
  (kill-local-variable 'tool-bar-map))

;;; Main mode

(defun fstar-teardown ()
  "Run all teardown functions."
  (unless (buffer-base-buffer)
    (fstar-run-module-functions 'teardown)))

(defun fstar-setup-hooks ()
  "Setup hooks required by F*-mode."
  (add-hook 'before-revert-hook #'fstar-subp-kill nil t)
  (add-hook 'change-major-mode-hook #'fstar-teardown nil t)
  (add-hook 'before-revert-hook #'fstar-teardown nil t)
  (add-hook 'kill-buffer-hook #'fstar-teardown nil t))

(defun fstar-teardown-hooks ()
  "Remove hooks required by F*-mode."
  (remove-hook 'before-revert-hook #'fstar-subp-kill t)
  (remove-hook 'change-major-mode-hook #'fstar-teardown t)
  (remove-hook 'before-revert-hook #'fstar-teardown t)
  (remove-hook 'kill-buffer-hook #'fstar-teardown t))

(defun fstar-run-module-functions (kind)
  "Enable or disable F* mode components.
KIND is `setup', `teardown', or `unload'."
  (dolist (module (cons 'hooks fstar-enabled-modules))
    (let* ((fsymb (intern (format "fstar-%S-%S" kind module))))
      (when (fboundp fsymb)
        (funcall fsymb)))))

;;;###autoload
(define-derived-mode fstar-mode prog-mode '("" fstar--spin-modename fstar-subp--modeline-label)
  :syntax-table fstar-syntax-table
  (fstar-run-module-functions 'setup))

(defun fstar-mode-unload-function ()
  "Unload F* mode components."
  (fstar-run-module-functions 'teardown)
  (fstar-run-module-functions 'unload))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fsti?\\'" . fstar-mode))

;;; Footer

;; Local Variables:
;; checkdoc-verb-check-experimental-flag: nil
;; End:

(provide 'fstar-mode)
;;; fstar-mode.el ends here
