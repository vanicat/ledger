;;; ldg-report.el --- Helper code for use with the "ledger" command-line tool

;; Copyright (C) 2003-2013 John Wiegley (johnw AT gnu DOT org)

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 2, or (at your option) any later
;; version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.


;;; Commentary:
;;  Provide facilities for running and saving reports in emacs

;;; Code:

(eval-when-compile
  (require 'cl))

(defgroup ledger-report nil
  "Customization option for the Report buffer"
  :group 'ledger)

(defcustom ledger-reports
  '(("bal" "ledger -f %(ledger-file) bal")
    ("reg" "ledger -f %(ledger-file) reg")
    ("payee" "ledger -f %(ledger-file) reg @%(payee)")
    ("account" "ledger -f %(ledger-file) reg %(account)"))
  "Definition of reports to run.

Each element has the form (NAME CMDLINE).  The command line can
contain format specifiers that are replaced with context sensitive
information.  Format specifiers have the format '%(<name>)' where
<name> is an identifier for the information to be replaced.  The
`ledger-report-format-specifiers' alist variable contains a mapping
from format specifier identifier to a Lisp function that implements
the substitution.  See the documentation of the individual functions
in that variable for more information on the behavior of each
specifier."
  :type '(repeat (list (string :tag "Report Name")
		  (string :tag "Command Line")))
  :group 'ledger-report)

(defcustom ledger-report-format-specifiers
  '(("ledger-file" . ledger-report-ledger-file-format-specifier)
    ("payee" . ledger-report-payee-format-specifier)
    ("account" . ledger-report-account-format-specifier)
    ("value" . ledger-report-value-format-specifier))
  "An alist mapping ledger report format specifiers to implementing functions.

The function is called with no parameters and expected to return the
text that should replace the format specifier."
  :type 'alist
  :group 'ledger-report)

(defvar ledger-report-buffer-name "*Ledger Report*")

(defvar ledger-report-name nil)
(defvar ledger-report-cmd nil)
(defvar ledger-report-name-prompt-history nil)
(defvar ledger-report-cmd-prompt-history nil)
(defvar ledger-original-window-cfg nil)
(defvar ledger-report-saved nil)
(defvar ledger-minibuffer-history nil)
(defvar ledger-report-mode-abbrev-table)

(defun ledger-report-reverse-lines ()
  (interactive)
  (goto-char (point-min))
  (forward-paragraph)
  (next-line)
  (save-excursion
    (setq inhibit-read-only t)
    (reverse-region (point) (point-max))))

(define-derived-mode ledger-report-mode text-mode "Ledger-Report"
   "A mode for viewing ledger reports."
   (let ((map (make-sparse-keymap)))
     (define-key map [? ] 'scroll-up)
     (define-key map [backspace] 'scroll-down)
     (define-key map [?r] 'ledger-report-redo)
     (define-key map [(shift ?r)] 'ledger-report-reverse-lines)
     (define-key map [?s] 'ledger-report-save)
     (define-key map [?k] 'ledger-report-kill)
     (define-key map [?e] 'ledger-report-edit)
     (define-key map [?q] 'ledger-report-quit)
     (define-key map [(control ?c) (control ?l) (control ?r)]
       'ledger-report-redo)
     (define-key map [(control ?c) (control ?l) (control ?S)]
       'ledger-report-save)
     (define-key map [(control ?c) (control ?l) (control ?k)]
       'ledger-report-kill)
     (define-key map [(control ?c) (control ?l) (control ?e)]
       'ledger-report-edit)
     (define-key map [(control ?c) (control ?c)] 'ledger-report-visit-source)

     
     (define-key map [menu-bar] (make-sparse-keymap "ldg-rep"))
     (define-key map [menu-bar ldg-rep] (cons "Reports" map))

     (define-key map [menu-bar ldg-rep lrq] '("Quit" . ledger-report-quit))
     (define-key map [menu-bar ldg-rep s2] '("--"))
     (define-key map [menu-bar ldg-rep lrd] '("Scroll Down" . scroll-down))
     (define-key map [menu-bar ldg-rep vis] '("Visit Source" . ledger-report-visit-source))
     (define-key map [menu-bar ldg-rep lru] '("Scroll Up" . scroll-up))
     (define-key map [menu-bar ldg-rep s1] '("--"))
     (define-key map [menu-bar ldg-rep rev] '("Reverse report order" . ledger-report-reverse-lines))
     (define-key map [menu-bar ldg-rep s0] '("--"))
     (define-key map [menu-bar ldg-rep lrk] '("Kill Report" . ledger-report-kill))
     (define-key map [menu-bar ldg-rep lrr] '("Re-run Report" . ledger-report-redo))
     (define-key map [menu-bar ldg-rep lre] '("Edit Report" . ledger-report-edit))
     (define-key map [menu-bar ldg-rep lrs] '("Save Report" . ledger-report-save))

     (use-local-map map)))

(defun ledger-report-value-format-specifier ()
  "Return a valid meta-data tag name"
  ;; It is intended completion should be available on existing account
  ;; names, but it remains to be implemented.
  (ledger-read-string-with-default "Value: " nil))

(defun ledger-report-read-name ()
  "Read the name of a ledger report to use, with completion.

The empty string and unknown names are allowed."
  (completing-read "Report name: "
                   ledger-reports nil nil nil
                   'ledger-report-name-prompt-history nil))

(defun ledger-report (report-name edit)
  "Run a user-specified report from `ledger-reports'.

Prompts the user for the REPORT-NAME of the report to run or
EDIT.  If no name is entered, the user will be prompted for a
command line to run.  The command line specified or associated
with the selected report name is run and the output is made
available in another buffer for viewing.  If a prefix argument is
given and the user selects a valid report name, the user is
prompted with the corresponding command line for editing before
the command is run.

The output buffer will be in `ledger-report-mode', which defines
commands for saving a new named report based on the command line
used to generate the buffer, navigating the buffer, etc."
  (interactive
   (progn
     (when (and (buffer-modified-p)
                (y-or-n-p "Buffer modified, save it? "))
       (save-buffer))
     (let ((rname (ledger-report-read-name))
           (edit (not (null current-prefix-arg))))
       (list rname edit))))
  (let ((buf (current-buffer))
        (rbuf (get-buffer ledger-report-buffer-name))
        (wcfg (current-window-configuration)))
    (if rbuf
        (kill-buffer rbuf))
    (with-current-buffer
        (pop-to-buffer (get-buffer-create ledger-report-buffer-name))
      (ledger-report-mode)
      (set (make-local-variable 'ledger-report-saved) nil)
      (set (make-local-variable 'ledger-buf) buf)
      (set (make-local-variable 'ledger-report-name) report-name)
      (set (make-local-variable 'ledger-original-window-cfg) wcfg)
      (ledger-do-report (ledger-report-cmd report-name edit))
      (shrink-window-if-larger-than-buffer)
      (set-buffer-modified-p nil)
      (setq buffer-read-only t)
      (message "q to quit; r to redo; e to edit; k to kill; s to save; SPC and DEL to scroll"))))

(defun string-empty-p (s)
  "Check S for the empty string."
  (string-equal "" s))

(defun ledger-report-name-exists (name)
  "Check to see if the given report NAME exists.

   If name exists, returns the object naming the report,
   otherwise returns nil."
  (unless (string-empty-p name)
    (car (assoc name ledger-reports))))

(defun ledger-reports-add (name cmd)
  "Add a new report NAME and CMD to `ledger-reports'."
  (setq ledger-reports (cons (list name cmd) ledger-reports)))

(defun ledger-reports-custom-save ()
  "Save the `ledger-reports' variable using the customize framework."
  (customize-save-variable 'ledger-reports ledger-reports))

(defun ledger-report-read-command (report-cmd)
  "Read the command line to create a report from REPORT-CMD."
  (read-from-minibuffer "Report command line: "
                        (if (null report-cmd) "ledger " report-cmd)
                        nil nil 'ledger-report-cmd-prompt-history))

(defun ledger-report-ledger-file-format-specifier ()
  "Substitute the full path to master or current ledger file.

   The master file name is determined by the variable `ledger-master-file'
   buffer-local variable which can be set using file variables.
   If it is set, it is used, otherwise the current buffer file is
   used."
  (ledger-master-file))

;; General helper functions

(defvar ledger-master-file nil)

(defun ledger-master-file ()
  "Return the master file for a ledger file.

   The master file is either the file for the current ledger buffer or the
   file specified by the buffer-local variable `ledger-master-file'.  Typically
   this variable would be set in a file local variable comment block at the
   end of a ledger file which is included in some other file."
  (if ledger-master-file
      (expand-file-name ledger-master-file)
      (buffer-file-name)))

(defun ledger-read-string-with-default (prompt default)
  "Return user supplied string after PROMPT, or DEFAULT."
  (let ((default-prompt (concat prompt
                                (if default
                                    (concat " (" default "): ")
				    ": "))))
    (read-string default-prompt nil 'ledger-minibuffer-history default)))

(defun ledger-report-payee-format-specifier ()
  "Substitute a payee name.

   The user is prompted to enter a payee and that is substitued.  If
   point is in an entry, the payee for that entry is used as the
   default."
  ;; It is intended completion should be available on existing
  ;; payees, but the list of possible completions needs to be
  ;; developed to allow this.
  (ledger-read-string-with-default "Payee" (regexp-quote (ledger-xact-payee))))

(defun ledger-report-account-format-specifier ()
  "Substitute an account name.

   The user is prompted to enter an account name, which can be any
   regular expression identifying an account.  If point is on an account
   transaction line for an entry, the full account name on that line is
   the default."
  ;; It is intended completion should be available on existing account
  ;; names, but it remains to be implemented.
  (ledger-post-read-account-with-prompt "Account"))

(defun ledger-report-expand-format-specifiers (report-cmd)
  "Expand %(account) and %(payee) appearing in REPORT-CMD with thing under point."
  (save-match-data
    (let ((expanded-cmd report-cmd))
      (set-match-data (list 0 0))
      (while (string-match "%(\\([^)]*\\))" expanded-cmd (if (> (length expanded-cmd) (match-end 0))
							     (match-end 0)
							     (1- (length expanded-cmd))))
	(let* ((specifier (match-string 1 expanded-cmd))
	       (f (cdr (assoc specifier ledger-report-format-specifiers))))
	  (if f
	      (setq expanded-cmd (replace-match
				  (save-match-data
				    (with-current-buffer ledger-buf
				      (shell-quote-argument (funcall f))))
				  t t expanded-cmd)))))
      expanded-cmd)))

(defun ledger-report-cmd (report-name edit)
  "Get the command line to run the report name REPORT-NAME.
Optional EDIT the command."
  (let ((report-cmd (car (cdr (assoc report-name ledger-reports)))))
    ;; logic for substitution goes here
    (when (or (null report-cmd) edit)
      (setq report-cmd (ledger-report-read-command report-cmd))
      (setq ledger-report-saved nil)) ;; this is a new report, or edited report
    (setq report-cmd (ledger-report-expand-format-specifiers report-cmd))
    (set (make-local-variable 'ledger-report-cmd) report-cmd)
    (or (string-empty-p report-name)
        (ledger-report-name-exists report-name)
        (progn
	  (ledger-reports-add report-name report-cmd)
	  (ledger-reports-custom-save)))
    report-cmd))

(defun ledger-do-report (cmd)
  "Run a report command line CMD."
  (goto-char (point-min))
  (insert (format "Report: %s\n" ledger-report-name)
          (format "Command: %s\n" cmd)
          (make-string (- (window-width) 1) ?=)
          "\n\n")
  (let ((data-pos (point))
        (register-report (string-match " reg\\(ister\\)? " cmd))
	files-in-report)
    (shell-command
     ;; --subtotal does not produce identifiable transactions, so don't
     ;; prepend location information for them
     (if (and register-report
	      (not (string-match "--subtotal" cmd)))
	 (concat cmd " --prepend-format='%(filename):%(beg_line):'")
	 cmd)
     t nil)
    (when register-report
      (goto-char data-pos)
      (while (re-search-forward "^\\(/[^:]+\\)?:\\([0-9]+\\)?:" nil t)
	(let ((file (match-string 1))
	      (line (string-to-number (match-string 2))))
	  (delete-region (match-beginning 0) (match-end 0))
	  (when file 	    
	    (set-text-properties (line-beginning-position) (line-end-position)
				 (list 'ledger-source (cons file (save-window-excursion
								   (save-excursion
								     (find-file file)
								     (widen)
								     (ledger-goto-line line)
								     (point-marker))))))
	    (add-text-properties (line-beginning-position) (line-end-position)
				 (list 'face 'ledger-font-report-clickable-face))
	    (end-of-line)))))
    (goto-char data-pos)))


(defun ledger-report-visit-source ()
  "Visit the transaction under point in the report window."
  (interactive)
  (let* ((prop (get-text-property (point) 'ledger-source))
	 (file (if prop (car prop)))
	 (line-or-marker (if prop (cdr prop))))
    (when (and file line-or-marker)      
      (find-file-other-window file)
      (widen)
      (if (markerp line-or-marker)
	  (goto-char line-or-marker)
	  (goto-char (point-min))
	  (forward-line (1- line-or-marker))
	  (re-search-backward "^[0-9]+")
	  (beginning-of-line)
	  (let ((start-of-txn (point)))
	    (forward-paragraph)
	    (narrow-to-region start-of-txn (point))
	    (backward-paragraph))))))

(defun ledger-report-goto ()
  "Goto the ledger report buffer."
  (interactive)
  (let ((rbuf (get-buffer ledger-report-buffer-name)))
    (if (not rbuf)
        (error "There is no ledger report buffer"))
    (pop-to-buffer rbuf)
    (shrink-window-if-larger-than-buffer)))

(defun ledger-report-redo ()
  "Redo the report in the current ledger report buffer."
  (interactive)
  (ledger-report-goto)
  (setq buffer-read-only nil)
  (erase-buffer)
  (ledger-do-report ledger-report-cmd)
  (setq buffer-read-only nil))

(defun ledger-report-quit ()
  "Quit the ledger report buffer by burying it."
  (interactive)
  (ledger-report-goto)
  (set-window-configuration ledger-original-window-cfg)
  (bury-buffer (get-buffer ledger-report-buffer-name)))

(defun ledger-report-kill ()
  "Kill the ledger report buffer."
  (interactive)
  (ledger-report-quit)
  (kill-buffer (get-buffer ledger-report-buffer-name)))

(defun ledger-report-edit ()
  "Edit the defined ledger reports."
  (interactive)
  (customize-variable 'ledger-reports))

(defun ledger-report-read-new-name ()
  "Read the name for a new report from the minibuffer."
  (let ((name ""))
    (while (string-empty-p name)
      (setq name (read-from-minibuffer "Report name: " nil nil nil
                                       'ledger-report-name-prompt-history)))
    name))

(defun ledger-report-save ()
  "Save the current report command line as a named report."
  (interactive)
  (ledger-report-goto)
  (let (existing-name)
    (when (string-empty-p ledger-report-name)
      (setq ledger-report-name (ledger-report-read-new-name)))

    (if (setq existing-name (ledger-report-name-exists ledger-report-name))
	(cond ((y-or-n-p (format "Overwrite existing report named '%s'? "
				 ledger-report-name))
	       (if (string-equal
		    ledger-report-cmd
		    (car (cdr (assq existing-name ledger-reports))))
		   (message "Nothing to save. Current command is identical to existing saved one")
		   (progn
		     (setq ledger-reports
			   (assq-delete-all existing-name ledger-reports))
		     (ledger-reports-add ledger-report-name ledger-report-cmd)
		     (ledger-reports-custom-save))))
	      (t
	       (progn
		 (setq ledger-report-name (ledger-report-read-new-name))
		 (ledger-reports-add ledger-report-name ledger-report-cmd)
		 (ledger-reports-custom-save)))))))

(defconst ledger-line-config
  '((entry
     (("^\\(\\([0-9][0-9][0-9][0-9]/\\)?[01]?[0-9]/[0123]?[0-9]\\)[ \t]+\\(\\([!*]\\)[ \t]\\)?[ \t]*\\((\\(.*\\))\\)?[ \t]*\\(.*?\\)[ \t]*;\\(.*\\)[ \t]*$"
       (date nil status nil nil code payee comment))
      ("^\\(\\([0-9][0-9][0-9][0-9]/\\)?[01]?[0-9]/[0123]?[0-9]\\)[ \t]+\\(\\([!*]\\)[ \t]\\)?[ \t]*\\((\\(.*\\))\\)?[ \t]*\\(.*\\)[ \t]*$"
       (date nil status nil nil code payee))))
    (acct-transaction
     (("^\\([ \t]+;\\|;\\)\\s-?\\(.*\\)"
       (indent comment))
      ("\\(^[ \t]+\\)\\([:A-Za-z0-9]+?\\)\\s-\\s-+\\([$€£]\\s-?\\)\\(-?[0-9]*\\(\\.[0-9]*\\)?\\)$"
       (indent account commodity amount))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\([$€£]\\s-?\\)\\(-?[0-9]*\\(\\.[0-9]*\\)?\\)[ \t]*;[ \t]*\\(.*?\\)[ \t]*$"
       (indent account commodity amount nil comment))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\(-?[0-9]+\\(\\.[0-9]*\\)?\\)[ \t]+\\(.*?\\)[ \t]*\\(;[ \t]*\\(.*?\\)[ \t]*$\\|@+\\)"
       (indent account amount nil commodity comment))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\(-?[0-9]+\\(\\.[0-9]*\\)?\\)[ \t]+\\(.*?\\)[ \t]*$"
       (indent account amount nil commodity))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\(-?\\(\\.[0-9]*\\)\\)[ \t]+\\(.*?\\)[ \t]*;[ \t]*\\(.*?\\)[ \t]*$"
       (indent account amount nil commodity comment))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\(-?\\(\\.[0-9]*\\)\\)[ \t]+\\(.*?\\)[ \t]*$"
       (indent account amount nil commodity))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]*;[ \t]*\\(.*?\\)[ \t]*$"
       (indent account comment))
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]*$"
       (indent account))

;; Bad regexes
      ("\\(^[ \t]+\\)\\(.*?\\)[ \t]+\\([$€£]\\s-?\\)\\(-?[0-9]*\\(\\.[0-9]*\\)?\\)[ \t]*$"
       (indent account commodity amount nil))

      ))))

(defun ledger-extract-context-info (line-type pos)
  "Get context info for current line with LINE-TYPE.

Assumes point is at beginning of line, and the POS argument specifies
where the \"users\" point was."
  (let ((linfo (assoc line-type ledger-line-config))
        found field fields)
    (dolist (re-info (nth 1 linfo))
      (let ((re (nth 0 re-info))
            (names (nth 1 re-info)))
        (unless found
          (when (looking-at re)
            (setq found t)
            (dotimes (i (length names))
              (when (nth i names)
                (setq fields (append fields
                                     (list
                                      (list (nth i names)
                                            (match-string-no-properties (1+ i))
                                            (match-beginning (1+ i))))))))
            (dolist (f fields)
              (and (nth 1 f)
                   (>= pos (nth 2 f))
                   (setq field (nth 0 f))))))))
    (list line-type field fields)))

(defun ledger-context-at-point ()
  "Return a list describing the context around point.

The contents of the list are the line type, the name of the field
point containing point, and for selected line types, the content of
the fields in the line in a association list."
  (let ((pos (point)))
    (save-excursion
      (beginning-of-line)
      (let ((first-char (char-after)))
        (cond ((equal (point) (line-end-position))
               '(empty-line nil nil))
              ((memq first-char '(?\ ?\t))
               (ledger-extract-context-info 'acct-transaction pos))
              ((memq first-char '(?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9))
               (ledger-extract-context-info 'entry pos))
              ((equal first-char ?\=)
               '(automated-entry nil nil))
              ((equal first-char ?\~)
               '(period-entry nil nil))
              ((equal first-char ?\!)
               '(command-directive))
              ((equal first-char ?\;)
               '(comment nil nil))
              ((equal first-char ?Y)
               '(default-year nil nil))
              ((equal first-char ?P)
               '(commodity-price nil nil))
              ((equal first-char ?N)
               '(price-ignored-commodity nil nil))
              ((equal first-char ?D)
               '(default-commodity nil nil))
              ((equal first-char ?C)
               '(commodity-conversion nil nil))
              ((equal first-char ?i)
               '(timeclock-i nil nil))
              ((equal first-char ?o)
               '(timeclock-o nil nil))
              ((equal first-char ?b)
               '(timeclock-b nil nil))
              ((equal first-char ?h)
               '(timeclock-h  nil nil))
              (t
               '(unknown nil nil)))))))

(defun ledger-context-other-line (offset)
  "Return a list describing context of line OFFSET from existing position.

Offset can be positive or negative.  If run out of buffer before reaching
specified line, returns nil."
  (save-excursion
    (let ((left (forward-line offset)))
      (if (not (equal left 0))
          nil
	  (ledger-context-at-point)))))

(defun ledger-context-line-type (context-info)
  (nth 0 context-info))

(defun ledger-context-current-field (context-info)
  (nth 1 context-info))

(defun ledger-context-field-info (context-info field-name)
  (assoc field-name (nth 2 context-info)))

(defun ledger-context-field-present-p (context-info field-name)
  (not (null (ledger-context-field-info context-info field-name))))

(defun ledger-context-field-value (context-info field-name)
  (nth 1 (ledger-context-field-info context-info field-name)))

(defun ledger-context-field-position (context-info field-name)
  (nth 2 (ledger-context-field-info context-info field-name)))

(defun ledger-context-field-end-position (context-info field-name)
  (+ (ledger-context-field-position context-info field-name)
     (length (ledger-context-field-value context-info field-name))))

(defun ledger-context-goto-field-start (context-info field-name)
  (goto-char (ledger-context-field-position context-info field-name)))

(defun ledger-context-goto-field-end (context-info field-name)
  (goto-char (ledger-context-field-end-position context-info field-name)))

(provide 'ldg-report)

;;; ldg-report.el ends here
