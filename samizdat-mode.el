;;; samizdat-mode.el --- Major mode for samizdat documents -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;; Keywords: text, wp
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Editing `.sz' files, the markup read by samizdat.
;;
;; The parts of the syntax that span lines — `|{ ... }|' verbatim bodies,
;; `@;{ ... }' comments, `@"..."' literals and the strings inside `[...]' and
;; `(meta ...)' — are found by `samizdat-syntax-propertize' and marked as
;; strings and comments in the syntax table. Everything that asks where it is
;; (font-lock, filling, `syntax-ppss') then agrees with the reader about what
;; is text, and an `@' inside code is not a command.
;;
;;   C-c C-e   a command around the region, or an empty one
;;   C-c C-s   a section; with a prefix argument, the level to use
;;   C-c C-b   a code block around the region, or an empty one
;;   C-c C-l   a link around the region
;;   C-c '     the verbatim body at point, in a buffer of its language's mode
;;   C-c C-o   what the command at point names: a link, or a file it reads
;;   C-c C-f   fold to the headings; with a prefix argument, the level to show
;;   C-c C-a   unfold everything
;;
;; `outline-minor-mode' folds sections: TAB on a heading folds and unfolds
;; it, S-TAB cycles the whole document, and `C-c @' has the rest of
;; outline's commands. `imenu' lists the sections.

;;; Code:

(require 'outline)
(require 'seq)
(require 'subr-x)

(defgroup samizdat nil
  "Major mode for samizdat documents."
  :group 'text)

(defcustom samizdat-command-names
  '("blockquote" "br" "checkbox" "code" "codeblock" "comment" "def" "deflist"
    "div" "em" "hr" "image" "include" "include-markdown" "item" "itemlist"
    "lineblock" "link" "markdown" "note" "numbered-headings" "raw" "raw-block" "read-list"
    "read-table" "ref" "section" "section*" "span" "strike" "strong" "sub"
    "subsection" "subsection*" "subsubsection" "subsubsection*" "sup" "term"
    "toc")
  "Command names offered by completion and `samizdat-insert-command'.
The standard commands; add the ones your blog defines."
  :type '(repeat string))

(defcustom samizdat-block-commands
  '("blockquote" "codeblock" "comment" "def" "deflist" "div" "hr" "image"
    "include" "include-markdown" "item" "itemlist" "lineblock" "markdown"
    "numbered-headings" "raw-block" "read-list" "read-table" "section" "section*" "subsection"
    "subsection*" "subsubsection" "subsubsection*" "term" "toc")
  "Commands that make blocks.
A line that begins with one begins a paragraph, so filling does not
join it to the text above."
  :type '(repeat string))

(defcustom samizdat-code-block-modes
  '(("scheme" . scheme-mode)
    ("bjolang" . bjo-mode)
    ("bjo" . bjo-mode)
    ("sh" . sh-mode)
    ("shell" . sh-mode)
    ("elisp" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("markdown" . markdown-mode)
    ("text" . text-mode))
  "Major modes for the languages of code blocks, for \\[samizdat-edit-code-block].
The key is a `#:lang', or the name of the command when it has none, as
for `@markdown'. A language not listed here is tried as LANG-ts-mode
and then LANG-mode."
  :type '(alist :key-type string :value-type function))

(defcustom samizdat-fold-sections t
  "Whether `samizdat-mode' turns on `outline-minor-mode'.
With it, TAB on a heading line folds and unfolds that section, and
S-TAB folds the whole document."
  :type 'boolean)

(defcustom samizdat-heading-indent 2
  "How many columns each heading level below a section is shown indented.
Only the display is indented, not the text, so that the levels stand
apart when the document is folded to its headings. 0 shows them as
they are."
  :type 'natnum)

;;; ---------------------------------------------------------------------------
;;; Faces

(defface samizdat-command-face
  '((t :inherit font-lock-keyword-face))
  "A command's `@' and name.")

(defface samizdat-verbatim-face
  '((t :inherit font-lock-constant-face))
  "A `|{ ... }|' body.")

(defface samizdat-literal-face
  '((t :inherit font-lock-string-face))
  "An `@\"...\"' literal.")

(defface samizdat-keyword-face
  '((t :inherit font-lock-builtin-face))
  "A `#:keyword' in a command's arguments or the meta form.")

(defface samizdat-section-face
  '((t :inherit outline-1))
  "The title of an `@section'.")

(defface samizdat-subsection-face
  '((t :inherit outline-2))
  "The title of an `@subsection'.")

(defface samizdat-subsubsection-face
  '((t :inherit outline-3))
  "The title of an `@subsubsection'.")

(defface samizdat-strike-face
  '((t :strike-through t))
  "The body of an `@strike'.")

(defface samizdat-emphasis-face
  '((t :inherit italic))
  "The body of an `@em'.")

(defface samizdat-strong-face
  '((t :inherit bold))
  "The body of an `@strong'.")

(defface samizdat-code-face
  '((t :inherit font-lock-constant-face))
  "The body of an `@code' written with braces.")

;;; ---------------------------------------------------------------------------
;;; Syntax

(defconst samizdat--name-re "[[:alpha:]][[:alnum:]_*/-]*"
  "A command name: a letter, then letters, digits and `- _ * /'.")

(defvar samizdat-mode-syntax-table
  (let ((table (make-syntax-table text-mode-syntax-table)))
    ;; Brackets pair so that bodies and arguments can be moved over and
    ;; matched. A quote is only a string where `samizdat-syntax-propertize'
    ;; says so — in prose it is punctuation.
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\" "." table)
    (modify-syntax-entry ?| "." table)
    (modify-syntax-entry ?@ "." table)
    table)
  "Syntax table for `samizdat-mode'.")

(defun samizdat--word-char-p (c)
  "Whether C is a letter or a digit."
  (and c (or (memq (get-char-code-property c 'general-category)
                   '(Lu Ll Lt Lm Lo Nd Nl No)))))

(defun samizdat--after-word-p (at)
  "Whether the `@' at AT comes right after a letter or a digit.
Such an `@' is text unless a command name and `[', `{' or `|' follow it."
  (samizdat--word-char-p (char-before at)))

(defun samizdat--fence (pos syntax)
  "Give the character at POS the syntax class SYNTAX."
  (put-text-property pos (1+ pos) 'syntax-table (string-to-syntax syntax)))

(defun samizdat--multiline (beg end)
  "Mark BEG to END as one construct.
An edit anywhere in it then propertizes all of it again, so that a
closing fence past the edit is not left behind; see
`syntax-propertize-multiline'."
  (put-text-property beg end 'syntax-multiline t))

(defun samizdat--matching-brace (open)
  "The position of the `}' that closes the `{' at OPEN, or nil.
Counts braces only, which is what a comment's body is held to."
  (save-excursion
    (goto-char (1+ open))
    (let ((depth 1))
      (while (and (> depth 0) (skip-chars-forward "^{}") (not (eobp)))
        (setq depth (if (eq (char-after) ?\{) (1+ depth) (1- depth)))
        (forward-char 1))
      (and (= depth 0) (1- (point))))))

(defun samizdat--propertize-comment (at)
  "Mark the comment whose `@;' is at AT."
  (goto-char (+ at 2))
  (if (eq (char-after) ?\{)
      (let ((close (samizdat--matching-brace (point))))
        (when close
          (samizdat--fence at "!")
          (samizdat--fence close "!")
          (samizdat--multiline at (1+ close))
          (goto-char (1+ close))))
    (samizdat--fence at "!")
    (end-of-line)
    (unless (eobp)
      (samizdat--fence (point) "!")
      (forward-char 1))))

(defun samizdat--string-end (from)
  "The position of the `\"' that ends a string whose text starts at FROM.
A backslash escapes the character after it. Nil when there is none."
  (save-excursion
    (goto-char from)
    (let (found)
      (while (and (not found) (re-search-forward "[\"\\]" nil t))
        (if (eq (char-before) ?\\)
            (forward-char 1)
          (setq found (1- (point)))))
      found)))

(defun samizdat--propertize-literal (at)
  "Mark the `@\"...\"' literal whose `@' is at AT."
  (let ((close (samizdat--string-end (+ at 2))))
    (when close
      (samizdat--fence at "|")
      (samizdat--fence close "|")
      (samizdat--multiline at (1+ close))
      (goto-char (1+ close)))))

(defun samizdat--propertize-data (open)
  "Mark strings, comments and characters in the bjodat group opened at OPEN.
That is a command's `[...]' or the `(meta ...)' form. A `#\\(' is a
character there, and not an opening bracket."
  (goto-char (1+ open))
  (let ((depth 1))
    (while (and (> depth 0) (re-search-forward "#\\\\\\|[][(){}\";]" nil t))
      (let ((mb (match-beginning 0)))
        (pcase (char-after mb)
          (?# (unless (eobp)
                (samizdat--fence (point) "_")
                (forward-char 1)))
          ((or ?\[ ?\( ?\{) (setq depth (1+ depth)))
          ((or ?\] ?\) ?\}) (setq depth (1- depth)))
          (?\" (let ((close (samizdat--string-end (1+ mb))))
                 (when close
                   (samizdat--fence mb "|")
                   (samizdat--fence close "|")
                   (goto-char (1+ close)))))
          (?\; (samizdat--fence mb "!")
               (end-of-line)
               (unless (eobp)
                 (samizdat--fence (point) "!")
                 (forward-char 1))))))))

(defun samizdat--command-before-p (pos)
  "Whether a command's name ends right before POS."
  (save-excursion
    (goto-char pos)
    (looking-back (concat "@" samizdat--name-re) (line-beginning-position))))

(defun samizdat--body-position-p (bar)
  "Whether the `|' at BAR stands where a command's body may begin.
That is right after a command's name, or after its `[...]'."
  (if (eq (char-before bar) ?\])
      (let ((open (ignore-errors (scan-lists bar -1 0))))
        (and open (samizdat--command-before-p open)))
    (samizdat--command-before-p bar)))

(defun samizdat--closer (punct)
  "The `}...|' that closes a verbatim body opened with `|PUNCT{'.
PUNCT reversed, with each bracket turned around."
  (concat "}"
          (apply #'string
                 (mapcar (lambda (c)
                           (pcase c
                             (?\( ?\)) (?\) ?\() (?\[ ?\]) (?\] ?\[)
                             (?< ?>) (?> ?<) (_ c)))
                         (reverse (string-to-list punct))))
          "|"))

(defun samizdat--propertize-verbatim (bar punct)
  "Mark the verbatim body whose opening `|' is at BAR, opened with PUNCT.
A pair of the same opener and closer inside it is text, as the reader
has it, so they are counted."
  (let* ((open (concat "|" punct "{"))
         (close (samizdat--closer punct))
         (re (concat (regexp-quote open) "\\|" (regexp-quote close)))
         (depth 1))
    (goto-char (+ bar (length open)))
    (while (and (> depth 0) (re-search-forward re nil t))
      (setq depth (if (equal (match-string 0) close) (1- depth) (1+ depth))))
    (if (= depth 0)
        (progn (samizdat--fence bar "|")
               (samizdat--fence (1- (point)) "|")
               (samizdat--multiline bar (point)))
      ;; Not closed yet, as while it is being typed: leave it as text rather
      ;; than make the rest of the buffer a string.
      (goto-char (+ bar (length open))))))

(defun samizdat--meta-start-p (pos)
  "Whether POS, a `(', is the first thing in the buffer."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t\n")
    (bobp)))

(defconst samizdat--special-re
  (concat "\\(@;\\)"
          "\\|\\(@\"\\)"
          "\\|\\(@" samizdat--name-re "\\[\\)"
          "\\|\\(|\\([^[:alnum:][:space:]{}|@]*\\){\\)"
          "\\|\\((meta[ \t\n)]\\)")
  "What begins a construct `samizdat-syntax-propertize' marks.")

(defun samizdat-syntax-propertize (start end)
  "Mark comments, literals, verbatim bodies and data between START and END.
A construct that begins here is marked to its end, which may be past END."
  (goto-char start)
  (while (and (< (point) end) (re-search-forward samizdat--special-re end t))
    (let ((mb (match-beginning 0))
          (me (match-end 0))
          (kind (seq-find #'match-beginning '(1 2 3 4 6)))
          (punct (match-string 5)))
      (goto-char me)
      (unless (save-excursion (nth 8 (syntax-ppss mb)))
        (pcase kind
          (1 (unless (samizdat--after-word-p mb) (samizdat--propertize-comment mb)))
          (2 (unless (samizdat--after-word-p mb) (samizdat--propertize-literal mb)))
          (3 (samizdat--propertize-data (1- me)))
          (4 (when (samizdat--body-position-p mb) (samizdat--propertize-verbatim mb punct)))
          (6 (when (samizdat--meta-start-p mb) (samizdat--propertize-data mb))))))))

;;; ---------------------------------------------------------------------------
;;; Where point is

(defun samizdat--in-verbatim-p (&optional pos)
  "Whether POS is inside a `|{ ... }|' body."
  (let ((ppss (save-excursion (syntax-ppss pos))))
    (and (nth 3 ppss) (eq (char-after (nth 8 ppss)) ?|))))

(defun samizdat--args-open-p (open)
  "Whether the bracket at OPEN opens a command's arguments."
  (and (eq (char-after open) ?\[) (samizdat--command-before-p open)))

(defun samizdat--meta-open-p (open)
  "Whether the paren at OPEN opens the meta form."
  (and (eq (char-after open) ?\()
       (save-excursion (goto-char open) (looking-at-p "(meta[ \t\n)]"))
       (samizdat--meta-start-p open)))

(defun samizdat--data-open (&optional pos)
  "The `[' or `(' of the arguments or meta form POS is in, or nil."
  (let ((ppss (save-excursion (syntax-ppss pos))))
    (unless (nth 8 ppss)
      (seq-find (lambda (open)
                  (or (samizdat--args-open-p open) (samizdat--meta-open-p open)))
                (reverse (nth 9 ppss))))))

(defun samizdat--in-meta-p (&optional pos)
  "Whether POS is inside the meta form."
  (let ((open (samizdat--data-open pos)))
    (and open (eq (char-after open) ?\())))

;;; ---------------------------------------------------------------------------
;;; Font lock

(defun samizdat--command-p (at name-end bar)
  "Whether the `@' at AT begins a command whose name ends at NAME-END.
BAR is non-nil for `@|name|', which is always a command."
  (let ((ppss (save-excursion (syntax-ppss at))))
    (cond
     ((nth 4 ppss) nil)
     ;; In a verbatim body only `|@' begins a command.
     ((nth 3 ppss) (and (eq (char-after (nth 8 ppss)) ?|) (eq (char-before at) ?|)))
     ((samizdat--data-open at) nil)
     ((and (not bar) (samizdat--after-word-p at))
      (memq (char-after name-end) '(?\[ ?\{ ?|)))
     (t t))))

(defun samizdat--match-command (limit)
  "Find the next command before LIMIT, for font lock."
  (let ((re (concat "@\\(?:\\(|\\)" samizdat--name-re "|\\|" samizdat--name-re "\\)"))
        found)
    (while (and (not found) (re-search-forward re limit t))
      (let ((md (match-data))
            (bar (match-beginning 1)))
        (when (save-excursion (save-match-data
                                (samizdat--command-p (match-beginning 0) (match-end 0) bar)))
          (set-match-data md)
          (setq found t))))
    found))

(defun samizdat--body-end (open)
  "The position after the `}' that closes the body opened at OPEN, or nil.
Braces inside literals, comments and verbatim bodies do not count."
  (save-excursion
    (goto-char (1+ open))
    (let ((depth 1))
      (while (and (> depth 0) (skip-chars-forward "^{}") (not (eobp)))
        (unless (nth 8 (syntax-ppss))
          (setq depth (if (eq (char-after) ?\{) (1+ depth) (1- depth))))
        (forward-char 1))
      (and (= depth 0) (point)))))

(defun samizdat--match-body (names limit)
  "Find the next command named one of NAMES before LIMIT that has a `{' body.
Group 1 is the body, without its braces."
  (let ((re (concat "@" (regexp-opt names) "\\([[{]\\)"))
        found)
    (while (and (not found) (re-search-forward re limit t))
      (let* ((at (match-beginning 0))
             (after-name (match-beginning 1))
             (open (save-excursion
                     (save-match-data
                       (goto-char after-name)
                       (when (eq (char-after) ?\[)
                         (goto-char (or (ignore-errors (scan-lists (point) 1 0)) (point))))
                       (and (eq (char-after) ?\{)
                            (samizdat--command-p at after-name nil)
                            (point)))))
             (end (and open (save-match-data (samizdat--body-end open)))))
        (when end
          (set-match-data (list at end (1+ open) (1- end)))
          (goto-char (1+ open))
          (setq found t))))
    found))

(defun samizdat--body-matcher (names)
  "A font-lock matcher for the bodies of commands named NAMES."
  (lambda (limit) (samizdat--match-body names limit)))

(defun samizdat--data-matcher (re &optional meta-only)
  "A font-lock matcher for RE in arguments and the meta form.
With META-ONLY, in the meta form only."
  (lambda (limit)
    (let (found)
      (while (and (not found) (re-search-forward re limit t))
        ;; Asked at the match's last character, which is inside the group even
        ;; when the match begins with the group's own opening paren.
        (let ((md (match-data))
              (inside (1- (match-end 0))))
          (when (save-excursion
                  (save-match-data
                    (if meta-only
                        (samizdat--in-meta-p inside)
                      (samizdat--data-open inside))))
            (set-match-data md)
            (setq found t))))
      found)))

(defvar samizdat-font-lock-keywords
  `((,(samizdat--body-matcher '("section" "section*")) (1 'samizdat-section-face prepend))
    (,(samizdat--body-matcher '("subsection" "subsection*")) (1 'samizdat-subsection-face prepend))
    (,(samizdat--body-matcher '("subsubsection" "subsubsection*")) (1 'samizdat-subsubsection-face prepend))
    (,(samizdat--body-matcher '("strike")) (1 'samizdat-strike-face prepend))
    (,(samizdat--body-matcher '("em")) (1 'samizdat-emphasis-face prepend))
    (,(samizdat--body-matcher '("strong")) (1 'samizdat-strong-face prepend))
    (,(samizdat--body-matcher '("code")) (1 'samizdat-code-face prepend))
    (samizdat--match-command (0 'samizdat-command-face t))
    (,(samizdat--data-matcher "#:[^][ \t\n(){}\";]+") (0 'samizdat-keyword-face))
    (,(samizdat--data-matcher "(\\(meta\\)[ \t\n)]" t) (1 'font-lock-keyword-face))
    (,(samizdat--data-matcher "(\\([[:alpha:]][^][ \t\n(){}\";]*\\)" t)
     (1 'font-lock-variable-name-face))
    (samizdat--match-heading-line (0 (samizdat--heading-prefix) prepend)))
  "Font-lock keywords for `samizdat-mode'.")

(defun samizdat--syntactic-face (state)
  "The face for the string or comment described by STATE."
  (cond
   ((nth 4 state) 'font-lock-comment-face)
   ((eq (char-after (nth 8 state)) ?|) 'samizdat-verbatim-face)
   ((eq (char-after (nth 8 state)) ?@) 'samizdat-literal-face)
   (t 'font-lock-string-face)))

(defvar font-lock-beg)
(defvar font-lock-end)

(defun samizdat--extend-region ()
  "Extend the region font lock is about to fontify to whole paragraphs.
A command's body may run over several lines, and its start has to be in
the region for its body to be found."
  (let ((beg (save-excursion
               (goto-char font-lock-beg)
               (if (re-search-backward "^[ \t]*$" nil t) (point) (point-min))))
        (end (save-excursion
               (goto-char font-lock-end)
               (if (re-search-forward "^[ \t]*$" nil t) (point) (point-max)))))
    (when (or (< beg font-lock-beg) (> end font-lock-end))
      (setq font-lock-beg (min beg font-lock-beg)
            font-lock-end (max end font-lock-end))
      t)))

;;; ---------------------------------------------------------------------------
;;; Filling

(defun samizdat-fill-paragraph (&optional _justify)
  "Leave verbatim bodies and the meta form alone; fill anything else as text."
  (if (or (samizdat--in-verbatim-p) (samizdat--in-meta-p))
      t
    nil))

(defun samizdat--fill-nobreak-p ()
  "Whether a line may not be broken here: inside arguments or a literal."
  (let ((ppss (syntax-ppss)))
    (or (and (nth 3 ppss) (not (eq (char-after (nth 8 ppss)) ?|)))
        (samizdat--data-open))))

;;; ---------------------------------------------------------------------------
;;; Sections

(defconst samizdat--section-re
  "^[ \t]*@\\(\\(?:sub\\)\\{0,2\\}section\\*?\\)\\(?:\\[[^]\n]*\\]\\)?{"
  "The start of a heading.")

(defun samizdat-outline-level ()
  "The level of the heading at point: 1 for a section."
  (save-excursion
    (skip-chars-forward " \t@")
    ;; Count how many `sub' prefixes precede `section' (ignoring a `*').
    (let ((name (buffer-substring-no-properties
                 (point) (progn (skip-chars-forward "a-z*") (point)))))
      (1+ (/ (- (length (replace-regexp-in-string "\\*" "" name))
                (length "section"))
             3)))))

(defconst samizdat--outline-regexp
  "[ \t]*@\\(?:sub\\)\\{0,2\\}section\\*?[[{]"
  "What `outline-minor-mode' takes to begin a heading line.")

(defun samizdat--heading-p (pos)
  "Whether the heading match at POS is a heading, and not in a verbatim
body, a comment, a literal or arguments."
  (save-excursion
    (save-match-data
      (goto-char pos)
      (skip-chars-forward " \t")
      (not (or (nth 8 (syntax-ppss)) (samizdat--data-open))))))

(defun samizdat-outline-search (&optional bound move backward looking-at)
  "Find a heading for outline, as `outline-search-function' does.
Search forward, or backward with BACKWARD, up to BOUND for a heading
that is not inside a verbatim body or a comment. When none is found,
point stays, or goes to BOUND with MOVE. With LOOKING-AT, answer only
whether point is at the start of a heading."
  (let ((re (concat "^" samizdat--outline-regexp)))
    (if looking-at
        (and (looking-at re) (samizdat--heading-p (point)))
      (let ((start (point))
            found)
        (while (and (not found)
                    (if backward
                        (re-search-backward re bound t)
                      (re-search-forward re bound t)))
          (when (samizdat--heading-p (match-beginning 0))
            (setq found t)))
        (unless found
          (goto-char (if move
                         (or bound (if backward (point-min) (point-max)))
                       start)))
        found))))

(defun samizdat--match-heading-line (limit)
  "Find the next heading line before LIMIT, for font lock.
The match is the whole line."
  (when (and (> samizdat-heading-indent 0) (samizdat-outline-search limit))
    (let ((bol (match-beginning 0)))
      (goto-char bol)
      (set-match-data (list bol (line-end-position)))
      (end-of-line)
      t)))

(defun samizdat--heading-prefix ()
  "The display properties that indent the heading line just matched."
  (let ((indent (* samizdat-heading-indent
                   (1- (save-excursion
                         (goto-char (match-beginning 0))
                         (samizdat-outline-level))))))
    (when (> indent 0)
      (let ((prefix (make-string indent ?\s)))
        `(face nil line-prefix ,prefix wrap-prefix ,prefix)))))

(defun samizdat-fold-to-sections (&optional level)
  "Show only the headings, down to LEVEL (default: all of them).
\\[universal-argument] or a number gives the level: 1 for sections only,
2 for subsections too."
  (interactive "P")
  (unless outline-minor-mode (outline-minor-mode 1))
  (outline-hide-sublevels (if level (prefix-numeric-value level) 3)))

(defun samizdat--imenu-index ()
  "The sections, subsections and subsubsections, for `imenu'."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward samizdat--section-re nil t)
        ;; Read before `samizdat--body-end', which searches.
        (let* ((head (match-beginning 0))
               (depth (/ (- (length (match-string 1)) (length "section")) 3))
               (open (1- (point)))
               (end (samizdat--body-end open))
               (title (and end (buffer-substring-no-properties (1+ open) (1- end)))))
          (when title
            (push (cons (concat (make-string (* 2 depth) ?\s)
                                (string-join (split-string title) " "))
                        head)
                  index)))))
    (nreverse index)))

;;; ---------------------------------------------------------------------------
;;; Inserting

(defun samizdat--read-command (prompt)
  "Read a command name with PROMPT."
  (completing-read prompt samizdat-command-names nil nil))

(defun samizdat--wrap (before after)
  "Put BEFORE and AFTER around the region, or insert both with point between."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (copy-marker (region-end))))
        (goto-char beg)
        (insert before)
        (goto-char end)
        (insert after)
        (set-marker end nil))
    (insert before)
    (save-excursion (insert after))))

(defun samizdat-insert-command (name)
  "Put `@NAME{...}' around the region, or insert it with point in the body."
  (interactive (list (samizdat--read-command "Command: ")))
  (samizdat--wrap (concat "@" name "{") "}"))

(defun samizdat-insert-section (level)
  "Insert a heading of LEVEL: 1 for a section, 2 and 3 for the ones below it.
With the region active, the region is its title."
  (interactive "p")
  (let ((name (pcase level (1 "section") (2 "subsection") (_ "subsubsection"))))
    (unless (use-region-p)
      (unless (bolp) (insert "\n"))
      (unless (save-excursion (forward-line -1) (looking-at-p "[ \t]*$"))
        (insert "\n")))
    (samizdat--wrap (concat "@" name "{") "}")))

(defun samizdat-insert-link (url)
  "Make the region a link to URL, or insert one with point in its text."
  (interactive "sURL: ")
  (samizdat--wrap (format "@link[%S]{" url) "}"))

(defun samizdat-insert-code-block (lang)
  "Put a code block in LANG around the region, or insert an empty one."
  (interactive "sLanguage: ")
  (let ((head (if (string-empty-p lang)
                  "@codeblock|{\n"
                (format "@codeblock[#:lang %S]|{\n" lang))))
    (if (use-region-p)
        (let ((beg (region-beginning))
              (end (copy-marker (region-end))))
          (goto-char end)
          (unless (bolp) (insert "\n"))
          (insert "}|")
          (goto-char beg)
          (insert head)
          (set-marker end nil))
      (unless (bolp) (insert "\n"))
      (insert head)
      (save-excursion (insert "\n}|\n")))))

(defun samizdat-completion-at-point ()
  "Complete a command name after an `@'."
  (let ((end (point)))
    (save-excursion
      (skip-chars-backward "[:alnum:]_*/-")
      (when (and (eq (char-before) ?@)
                 (not (nth 8 (syntax-ppss))))
        (list (point) end samizdat-command-names :exclusive 'no)))))

;;; ---------------------------------------------------------------------------
;;; Following what a command names

(defun samizdat--command-at-point ()
  "The command at point, as (NAME . ARGS-TEXT), or nil.
Point may be on its name or in its arguments."
  (save-excursion
    (let ((open (samizdat--data-open)))
      (cond
       ((and open (eq (char-after open) ?\[))
        (goto-char open))
       ((progn (skip-chars-backward "[:alnum:]_*/-")
               (eq (char-before) ?@))
        (skip-chars-forward "[:alnum:]_*/-"))
       (t (setq open nil)))
      (when (and (eq (char-after) ?\[) (samizdat--command-before-p (point)))
        (let ((beg (point))
              (end (ignore-errors (scan-lists (point) 1 0))))
          (when end
            (looking-back (concat "@\\(" samizdat--name-re "\\)") (line-beginning-position))
            (cons (match-string-no-properties 1)
                  (buffer-substring-no-properties (1+ beg) (1- end)))))))))

(defun samizdat--first-string (args)
  "The first positional string in ARGS, the text of a `[...]'."
  (when (string-match "\\`[ \t\n]*\"\\(\\(?:[^\"\\]\\|\\\\.\\)*\\)\"" args)
    (match-string 1 args)))

(defun samizdat--keyword-string (args key)
  "The string given for `#:KEY' in ARGS."
  (when (string-match (concat "#:" (regexp-quote key)
                              "[ \t\n]+\"\\(\\(?:[^\"\\]\\|\\\\.\\)*\\)\"")
                      args)
    (match-string 1 args)))

(defun samizdat--slug (text)
  "The id samizdat makes from TEXT: letters and digits, with dashes."
  (let ((kept (replace-regexp-in-string
               "[^[:alnum:] \t\n_-]" "" (downcase text))))
    (string-join (split-string kept "[ \t\n_-]+" t) "-")))

(defun samizdat--find-heading (id)
  "Go to the heading whose id is ID; answer whether there was one."
  (let ((found nil))
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (re-search-forward samizdat--section-re nil t))
        (let* ((head (match-beginning 0))
               (open (1- (point)))
               (args (save-excursion
                       (goto-char head)
                       (and (re-search-forward "\\[\\([^]]*\\)\\]" open t)
                            (match-string 1))))
               (end (samizdat--body-end open))
               (title (and end (buffer-substring-no-properties (1+ open) (1- end)))))
          (when (or (and args (equal (samizdat--keyword-string args "id") id))
                    (and title (equal (samizdat--slug title) id)))
            (setq found head)))))
    (when found (goto-char found) t)))

(defun samizdat-open-at-point ()
  "Follow the command at point.
A link opens in a browser, `@ref' goes to its heading, and `@include',
`@include-markdown', `@image' and `@codeblock[#:file ...]' visit the file,
relative to this one."
  (interactive)
  (pcase-let* ((`(,name . ,args) (or (samizdat--command-at-point)
                                     (user-error "No command with arguments at point")))
               (dir (if buffer-file-name (file-name-directory buffer-file-name) default-directory)))
    (pcase name
      ("link" (browse-url (or (samizdat--first-string args) (user-error "The link has no url"))))
      ("ref" (let ((id (or (samizdat--first-string args) (user-error "No id"))))
               (unless (samizdat--find-heading id)
                 (user-error "No heading here has the id %s" id))))
      ((or "include" "include-markdown" "image")
       (find-file (expand-file-name (or (samizdat--first-string args) (user-error "No file")) dir)))
      ("codeblock"
       (find-file (expand-file-name (or (samizdat--keyword-string args "file")
                                        (user-error "The code block names no #:file"))
                                    dir)))
      (_ (user-error "@%s names nothing to follow" name)))))

;;; ---------------------------------------------------------------------------
;;; Editing a code block in its own mode

(defvar-local samizdat--edit-origin nil
  "In a code block's edit buffer: (BUFFER BEG END MARGIN FIRST TRAIL).
BEG and END are markers around the body in BUFFER. MARGIN is the
indentation taken off the lines, FIRST the text of the line the `{'
ends when it was blank, and TRAIL the blank last line before the `}'.")

(defun samizdat--verbatim-bounds ()
  "The verbatim body at point, as (BAR OPEN-END CLOSE-BEG), or nil.
BAR is its opening `|', and the body runs from OPEN-END to CLOSE-BEG.
Point may be in the body, or on the line of the command it belongs to."
  (let ((bar (let ((ppss (syntax-ppss)))
               (if (and (nth 3 ppss) (eq (char-after (nth 8 ppss)) ?|))
                   (nth 8 ppss)
                 (save-excursion
                   (let ((eol (line-end-position)) found)
                     (beginning-of-line)
                     (while (and (not found) (search-forward "|" eol t))
                       (let ((s (syntax-ppss (point))))
                         (when (and (nth 3 s) (= (nth 8 s) (1- (point))))
                           (setq found (1- (point))))))
                     found))))))
    (when bar
      (let* ((open-end (save-excursion (goto-char bar) (search-forward "{") (point)))
             (punct (buffer-substring-no-properties (1+ bar) (1- open-end)))
             ;; Parsing from inside the string stops right after its end.
             (close-end (save-excursion
                          (goto-char (1+ bar))
                          (parse-partial-sexp (point) (point-max) nil nil
                                              (syntax-ppss (point)) 'syntax-table)
                          (point))))
        (list bar open-end (- close-end (length (samizdat--closer punct))))))))

(defun samizdat--block-language (bar)
  "The language of the verbatim body whose `|' is at BAR.
Its command's `#:lang', or the command's own name when it has none."
  (save-excursion
    (goto-char bar)
    (let ((args (when (eq (char-before) ?\])
                  (let ((open (scan-lists (point) -1 0)))
                    (prog1 (buffer-substring-no-properties (1+ open) (1- (point)))
                      (goto-char open))))))
      (or (and args (samizdat--keyword-string args "lang"))
          (and (looking-back (concat "@\\(" samizdat--name-re "\\)") (line-beginning-position))
               (match-string-no-properties 1))))))

(defun samizdat--language-mode (lang)
  "The major mode for LANG."
  (or (cdr (assoc lang samizdat-code-block-modes))
      (seq-find #'fboundp (list (intern (concat lang "-ts-mode"))
                                (intern (concat lang "-mode"))))
      #'fundamental-mode))

(defun samizdat--indentation (line)
  "How far LINE is indented."
  (- (length line) (length (string-trim-left line))))

(defun samizdat--blank-p (line)
  "Whether LINE is space, or nothing."
  (string-match-p "\\`[ \t]*\\'" line))

(defvar samizdat-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c '") #'samizdat-edit-commit)
    (define-key map (kbd "C-c C-c") #'samizdat-edit-commit)
    (define-key map (kbd "C-c C-k") #'samizdat-edit-abort)
    map)
  "Keymap for `samizdat-edit-mode'.")

(define-minor-mode samizdat-edit-mode
  "A code block of a samizdat document, being edited on its own."
  :lighter " sz-edit"
  (when samizdat-edit-mode
    (setq header-line-format
          (substitute-command-keys
           "Code block: \\[samizdat-edit-commit] to put it back, \\[samizdat-edit-abort] to leave it"))))

(defun samizdat-edit-code-block ()
  "Edit the verbatim body at point in a buffer of its language's mode.
The indentation the body's lines share is taken off here and put back
when it is returned, as the reader takes it off when it reads it."
  (interactive)
  (pcase-let* ((`(,bar ,beg ,end) (or (samizdat--verbatim-bounds)
                                      (user-error "No |{ ... }| body at point")))
               (lang (or (samizdat--block-language bar) "text"))
               (lines (split-string (buffer-substring-no-properties beg end) "\n"))
               (first (and (cdr lines) (samizdat--blank-p (car lines)) (car lines)))
               (trail (and (cdr lines) (samizdat--blank-p (car (last lines))) (car (last lines))))
               (inner (let ((ls (if first (cdr lines) lines)))
                        (if trail (butlast ls) ls)))
               (margin (let ((indents (mapcar #'samizdat--indentation
                                              (seq-remove #'samizdat--blank-p
                                                          (if first inner (cdr inner))))))
                         (if indents (apply #'min indents) 0)))
               (text (string-join
                      (seq-map-indexed
                       (lambda (line i)
                         (cond ((samizdat--blank-p line) "")
                               ((and (= i 0) (not first)) line)
                               (t (substring line (min margin (samizdat--indentation line))))))
                       inner)
                      "\n"))
               (origin (list (current-buffer) (copy-marker beg) (copy-marker end t)
                             margin first trail))
               (edit (generate-new-buffer (format "*samizdat %s: %s*" lang (buffer-name)))))
    (with-current-buffer edit
      (insert text)
      (funcall (samizdat--language-mode lang))
      (setq samizdat--edit-origin origin)
      (samizdat-edit-mode 1)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer edit)))

(defun samizdat-edit-commit ()
  "Put the code block back where it came from, indented as it was."
  (interactive)
  (pcase-let* ((`(,buffer ,beg ,end ,margin ,first ,trail) samizdat--edit-origin)
               (pad (make-string margin ?\s))
               (lines (split-string (buffer-string) "\n"))
               (body (string-join
                      (seq-map-indexed
                       (lambda (line i)
                         (cond ((samizdat--blank-p line) "")
                               ((and (= i 0) (not first)) line)
                               (t (concat pad line))))
                       lines)
                      "\n"))
               (text (concat (if first (concat first "\n") "")
                             body
                             (if trail (concat "\n" trail) ""))))
    (unless (buffer-live-p buffer)
      (user-error "The document this came from is gone"))
    (with-current-buffer buffer
      (save-excursion
        (goto-char beg)
        (delete-region beg end)
        (insert text)))
    (samizdat-edit-abort)))

(defun samizdat-edit-abort ()
  "Leave the code block as it is in the document."
  (interactive)
  (pcase-let ((`(,buffer ,beg ,end . ,_) samizdat--edit-origin))
    (set-marker beg nil)
    (set-marker end nil)
    (let ((edit (current-buffer)))
      (quit-window)
      (kill-buffer edit)
      (when (buffer-live-p buffer)
        (pop-to-buffer buffer)))))

;;; ---------------------------------------------------------------------------
;;; The mode

(defvar samizdat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-e") #'samizdat-insert-command)
    (define-key map (kbd "C-c C-s") #'samizdat-insert-section)
    (define-key map (kbd "C-c C-b") #'samizdat-insert-code-block)
    (define-key map (kbd "C-c C-l") #'samizdat-insert-link)
    (define-key map (kbd "C-c '") #'samizdat-edit-code-block)
    (define-key map (kbd "C-c C-o") #'samizdat-open-at-point)
    (define-key map (kbd "C-c C-f") #'samizdat-fold-to-sections)
    (define-key map (kbd "C-c C-a") #'outline-show-all)
    map)
  "Keymap for `samizdat-mode'.")

;;;###autoload
(define-derived-mode samizdat-mode text-mode "samizdat"
  "Major mode for samizdat documents.

\\{samizdat-mode-map}"
  :syntax-table samizdat-mode-syntax-table
  (setq-local parse-sexp-lookup-properties t)
  (setq-local syntax-propertize-function #'samizdat-syntax-propertize)
  (add-hook 'syntax-propertize-extend-region-functions
            #'syntax-propertize-multiline 'append 'local)
  (setq-local font-lock-defaults
              '(samizdat-font-lock-keywords
                nil nil nil nil
                (font-lock-syntactic-face-function . samizdat--syntactic-face)))
  (add-hook 'font-lock-extend-region-functions #'samizdat--extend-region nil t)
  (setq-local font-lock-multiline t)
  (setq-local font-lock-extra-managed-props
              (append '(line-prefix wrap-prefix) font-lock-extra-managed-props))
  (setq-local comment-start "@; ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "@;+[ \t]*")
  (setq-local fill-paragraph-function #'samizdat-fill-paragraph)
  (add-hook 'fill-nobreak-predicate #'samizdat--fill-nobreak-p nil t)
  (setq-local paragraph-start
              (concat "\f\\|[ \t]*$\\|[ \t]*\\(?:}\\|@"
                      (regexp-opt samizdat-block-commands)
                      "\\(?:[][{|[:space:]]\\|$\\)\\)"))
  (setq-local outline-regexp samizdat--outline-regexp)
  (setq-local outline-search-function #'samizdat-outline-search)
  (setq-local outline-level #'samizdat-outline-level)
  ;; TAB on a heading folds it, S-TAB folds the whole document.
  (setq-local outline-minor-mode-cycle t)
  (when samizdat-fold-sections (outline-minor-mode 1))
  (setq-local imenu-create-index-function #'samizdat--imenu-index)
  (add-hook 'completion-at-point-functions #'samizdat-completion-at-point nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.sz\\'" . samizdat-mode))

(provide 'samizdat-mode)

;;; samizdat-mode.el ends here
