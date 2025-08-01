;;; helm-for-files.el --- helm-for-files and related. -*- lexical-binding: t -*-

;; Copyright (C) 2012 ~ 2025 Thierry Volpiatto

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'helm-files)
(require 'helm-external)
(require 'helm-bookmark)

(defvar recentf-list)

(defcustom helm-multi-files-toggle-locate-binding "C-c p"
  "Default binding to switch back and forth locate in `helm-multi-files'."
  :group 'helm-files
  :type 'string)

(defcustom helm-for-files-preferred-list
  '(helm-source-buffers-list
    helm-source-recentf
    helm-source-bookmarks
    helm-source-file-cache
    helm-source-files-in-current-dir
    helm-source-locate)
  "Your preferred sources for `helm-for-files' and `helm-multi-files'.

When adding a source here it is up to you to ensure the library
of this source is accessible and properly loaded."
  :type '(repeat (choice symbol))
  :group 'helm-files)

(defcustom helm-for-files-tramp-not-fancy t
  "Colorize remote files when non nil.

Be aware that a nil value will make tramp display very slow."
  :group 'helm-files
  :type  'boolean)

;;; File Cache
;;
;;
(defvar file-cache-alist)

(defclass helm-file-cache (helm-source-in-buffer helm-type-file)
  ((init :initform (lambda () (require 'filecache)))))

(defun helm-file-cache-get-candidates ()
  (cl-loop for item in file-cache-alist append
           (cl-destructuring-bind (base &rest dirs) item
             (cl-loop for dir in dirs collect
                      (concat dir base)))))

(defvar helm-source-file-cache nil)

(defcustom helm-file-cache-fuzzy-match nil
  "Enable fuzzy matching in `helm-source-file-cache' when non--nil."
  :group 'helm-files
  :type 'boolean
  :set (lambda (var val)
         (set var val)
         (setq helm-source-file-cache
               (helm-make-source "File Cache" 'helm-file-cache
                 :fuzzy-match helm-file-cache-fuzzy-match
                 :data 'helm-file-cache-get-candidates))))

(cl-defun helm-file-cache-add-directory-recursively
    (dir &optional match (ignore-dirs t))
  (require 'filecache)
  (cl-loop for f in (helm-walk-directory
                     dir
                     :path 'full
                     :directories nil
                     :match match
                     :skip-subdirs ignore-dirs)
           do (file-cache-add-file f)))

(defun helm-transform-file-cache (actions _candidate)
  (let ((source (helm-get-current-source)))
    (if (string= (assoc-default 'name source) "File Cache")
        (append actions
                '(("Remove marked files from file-cache"
                   . helm-ff-file-cache-remove-file)))
        actions)))

;;; Recentf files
;;
;;
(defvar helm-recentf--basename-flag nil)

(defun helm-recentf-pattern-transformer (pattern)
  (let ((pattern-no-flag (replace-regexp-in-string " -b" "" pattern)))
    (cond ((and (string-match " " pattern-no-flag)
                (string-match " -b\\'" pattern))
           (setq helm-recentf--basename-flag t)
           pattern-no-flag)
        ((string-match "\\([^ ]*\\) -b\\'" pattern)
         (prog1 (match-string 1 pattern)
           (setq helm-recentf--basename-flag t)))
        (t (setq helm-recentf--basename-flag nil)
           pattern))))

(defcustom helm-turn-on-recentf t
  "Automatically turn on `recentf-mode' when non-nil."
  :group 'helm-files
  :type 'boolean)

(defclass helm-recentf-source (helm-source-sync helm-type-file)
  ((init :initform (lambda ()
                     (require 'recentf)
                     (when helm-turn-on-recentf (recentf-mode 1))))
   (candidates :initform 'recentf-list)
   (pattern-transformer :initform 'helm-recentf-pattern-transformer)
   (match-part :initform (lambda (candidate)
                           (if (or helm-ff-transformer-show-only-basename
                                   helm-recentf--basename-flag)
                               (helm-basename candidate) candidate)))
   ;; When real candidate is equal to display it gets corrupted with the text
   ;; properties added by the transformer, so ensure to strip out properties
   ;; before passing the candidate to action otherwise recentf will save the
   ;; candidate passed to find-file with the properties and corrupt
   ;; recentf-list. This happen when abbreviate-file-name is passed to a
   ;; candidate with no leading "~" e.g. "/foo" bug#2709.
   (coerce :initform 'substring-no-properties)
   (migemo :initform t)
   (persistent-action :initform 'helm-ff-kill-or-find-buffer-fname)))

(cl-defmethod helm--setup-source :after ((source helm-recentf-source))
  (setf (slot-value source 'action)
        (append (symbol-value (helm-actions-from-type-file))
                '(("Delete file(s) from recentf" .
                   (lambda (_candidate)
                     (cl-loop for file in (helm-marked-candidates)
                              do (setq recentf-list (delete file recentf-list)))))))))

(defvar helm-source-recentf nil
  "See (info \"(emacs)File Conveniences\").
Set `recentf-max-saved-items' to a bigger value if default is too
small.")

(defcustom helm-recentf-fuzzy-match nil
  "Enable fuzzy matching in `helm-source-recentf' when non-nil."
  :group 'helm-files
  :type 'boolean
  :set (lambda (var val)
         (set var val)
         (let ((helm-fuzzy-sort-fn 'helm-fuzzy-matching-sort-fn-preserve-ties-order))
           (setq helm-source-recentf
                 (helm-make-source "Recentf" 'helm-recentf-source
                   :fuzzy-match val)))))


;;; Transformer for helm-type-file
;;
;;
(defvar helm-sources-for-files-no-basename '("Recentf" "File Cache"))

;; Function `helm-highlight-files' is used in type `helm-type-file'. Ensure that
;; the definition is available for clients, should they need it.
;; See https://github.com/bbatsov/helm-projectile/issues/184.
;;;###autoload
(defun helm-highlight-files (files source)
  "A basic transformer for helm files sources.
Colorize only symlinks, directories and files."
  (cl-loop with mp-fn = (or (assoc-default
                             'match-part (helm-get-current-source))
                            'identity)
           with sname = (helm-get-attr 'name source)
           for i in files
           ;; As long as we use this transformer on file lists like recentf that
           ;; are printed and saved to a file we make a copy of the display
           ;; string and add text props to it, this to not corrupt the elemnts
           ;; of the original list (Bug#2709).
           for disp = (copy-sequence
                       (if (or (and (not helm-ff-show-dot-file-path)
                                    (helm-ff-dot-file-p i))
                               (and helm-ff-transformer-show-only-basename
                                    (not (member sname
                                                 helm-sources-for-files-no-basename))
                                    (not (helm-ff-dot-file-p i))
                                    (not (and helm--url-regexp
                                              (string-match helm--url-regexp i)))
                                    (not (string-match helm-ff-url-regexp i))))
                           (helm-basename i) (abbreviate-file-name i)))
           for isremote = (or (file-remote-p i)
                              (helm-file-on-mounted-network-p i))
           ;; file-attributes is too slow on remote files,
           ;; so call it only if:
           ;; - file is not remote
           ;; - helm-for-files--tramp-not-fancy is nil and file is remote AND
           ;; connected. (Bug#1679)
           for type = (and (or (null isremote)
                               (and (null helm-for-files-tramp-not-fancy)
                                    (file-remote-p i nil t)))
                           (car (file-attributes i)))
           collect
           (cond (;; No fancy display on remote files with basic predicates.
                  (and (null type) isremote) (cons disp i))
                 (;; Symlinks
                  (stringp type)
                  (add-text-properties 0 (length disp) `(face helm-ff-symlink
                                                         match-part ,(funcall mp-fn disp)
                                                         help-echo ,(expand-file-name i))
                                       disp)
                  (cons (helm-ff-prefix-filename disp i) i))
                 (;; Dotted dirs
                  (and (eq type t) (helm-ff-dot-file-p i))
                  (add-text-properties 0 (length disp) `(face helm-ff-dotted-directory
                                                         match-part ,(funcall mp-fn disp)
                                                         help-echo ,(expand-file-name i))
                                       disp)
                  (cons (helm-ff-prefix-filename disp i) i))
                 (;; Dirs
                  (eq type t)
                  (add-text-properties 0 (length disp) `(face helm-ff-directory
                                                         match-part ,(funcall mp-fn disp)
                                                         help-echo ,(expand-file-name i))
                                       disp)
                  (cons (helm-ff-prefix-filename disp i) i))
                 (t ;; Files.
                  (add-text-properties 0 (length disp) `(face helm-ff-file
                                                         match-part ,(funcall mp-fn disp)
                                                         help-echo ,(expand-file-name i))
                                       disp)
                  (helm-aif (helm-file-name-extension disp)
                      (when (condition-case _err
                                (string-match (format "\\.\\(%s\\)\\'" it) disp)
                              (invalid-regexp nil))
                        (add-face-text-property
                         (match-beginning 1) (match-end 1)
                         'helm-ff-file-extension nil disp)))
                  (cons (helm-ff-prefix-filename disp i) i)))))


;;; Files in current dir
;;
;;
(defclass helm-files-in-current-dir-source (helm-source-sync helm-type-file)
  ((candidates :initform (lambda ()
                           (with-helm-current-buffer
                             (let ((dir (helm-current-directory)))
                               (when (file-accessible-directory-p dir)
                                 (directory-files dir t))))))
   (pattern-transformer :initform 'helm-recentf-pattern-transformer)
   (match-part :initform (lambda (candidate)
                           (if (or helm-ff-transformer-show-only-basename
                                   helm-recentf--basename-flag)
                               (helm-basename candidate) candidate)))
   (fuzzy-match :initform t)
   (popup-info :initform (lambda (candidate)
                           (unless (helm-ff-dot-file-p candidate)
                             (helm-file-attributes
                              candidate
                              :dired t :human-size t :octal nil))))
   (migemo :initform t)))

(cl-defmethod helm--setup-source :after ((source helm-files-in-current-dir-source))
  (helm-aif (slot-value source 'filtered-candidate-transformer)
      (setf (slot-value source 'filtered-candidate-transformer)
            (append '(helm-ff-sort-candidates) (helm-mklist it)))))

(defvar helm-source-files-in-current-dir
  (helm-make-source "Files from Current Directory"
      'helm-files-in-current-dir-source
    :header-name (lambda (_name)
                   (format "Files from `%s'"
                           (abbreviate-file-name (helm-default-directory))))))

;;;###autoload
(defun helm-for-files ()
  "Preconfigured `helm' for opening files.
Run all sources defined in `helm-for-files-preferred-list'."
  (interactive)
  (require 'helm-x-files)
  (unless helm-source-buffers-list
    (setq helm-source-buffers-list
          (helm-make-source "Buffers" 'helm-source-buffers)))
  (helm :sources helm-for-files-preferred-list
        :ff-transformer-show-only-basename nil
        :buffer "*helm for files*"
        :truncate-lines helm-buffers-truncate-lines))

(defun helm-multi-files-toggle-to-locate ()
  (interactive)
  (with-helm-alive-p
    (with-helm-buffer
      (if (setq helm-multi-files--toggle-locate
                (not helm-multi-files--toggle-locate))
          (progn
            (helm-set-sources (unless (memq 'helm-source-locate
                                            helm-sources)
                                (cons 'helm-source-locate helm-sources)))
            (helm-set-source-filter '(helm-source-locate)))
          (helm-kill-async-processes)
          (helm-set-sources (remove 'helm-source-locate
                                    helm-for-files-preferred-list))
          (helm-set-source-filter nil)))))
(put 'helm-multi-files-toggle-to-locate 'helm-only t)

;;;###autoload
(defun helm-multi-files ()
  "Preconfigured helm like `helm-for-files' but running locate only on demand.

Allow toggling back and forth from locate to others sources with
`helm-multi-files-toggle-locate-binding' key.
This avoids launching locate needlessly when what you are
searching for is already found."
  (interactive)
  (require 'helm-x-files)
  (unless helm-source-buffers-list
    (setq helm-source-buffers-list
          (helm-make-source "Buffers" 'helm-source-buffers)))
  (setq helm-multi-files--toggle-locate nil)
  (helm-locate-set-command)
  (helm-set-local-variable 'helm-async-outer-limit-hook
                           (list (lambda ()
                                   (when (and helm-locate-fuzzy-match
                                              (not (string-match-p
                                                    "\\s-" helm-pattern)))
                                     (helm-redisplay-buffer))))
                           'helm-ff-transformer-show-only-basename nil)
  (let ((sources (remove 'helm-source-locate helm-for-files-preferred-list))
        (helm-locate-command
         (if helm-locate-fuzzy-match
             (unless (string-match-p "\\`locate -b" helm-locate-command)
               (replace-regexp-in-string
                "\\`locate" "locate -b" helm-locate-command))
             helm-locate-command))
        (old-key (lookup-key
                  helm-map
                  (read-kbd-macro helm-multi-files-toggle-locate-binding))))
    (with-helm-temp-hook 'helm-after-initialize-hook
      (define-key helm-map (kbd helm-multi-files-toggle-locate-binding)
        'helm-multi-files-toggle-to-locate))
    (unwind-protect
         (helm :sources sources
               :buffer "*helm multi files*"
               :truncate-lines helm-buffers-truncate-lines)
      (define-key helm-map (kbd helm-multi-files-toggle-locate-binding)
        old-key))))

;;;###autoload
(defun helm-recentf ()
  "Preconfigured `helm' for `recentf'."
  (interactive)
  (helm :sources 'helm-source-recentf
        :ff-transformer-show-only-basename nil
        :buffer "*helm recentf*"))

(provide 'helm-for-files)

;;; helm-for-files.el ends here
