#pragma once

#include <QHash>
#include <QJsonArray>
#include <QObject>
#include <QTimer>
#include <QVariantList>

// What the browser remembers, as small JSON files in
// ~/.local/share/flairweb: history, bookmarks, the new tab page's shortcuts,
// the last session, per-site zoom and finished downloads. Writes are batched
// and atomic (QSaveFile); flush() forces them out, at exit.
class Library : public QObject {
    Q_OBJECT
    Q_PROPERTY(int historyRevision READ historyRevision NOTIFY historyChanged)
    Q_PROPERTY(int bookmarksRevision READ bookmarksRevision NOTIFY bookmarksChanged)
    Q_PROPERTY(int dialRevision READ dialRevision NOTIFY dialChanged)
    Q_PROPERTY(int downloadsRevision READ downloadsRevision NOTIFY downloadsChanged)
    Q_PROPERTY(QString directory READ directory CONSTANT)

public:
    explicit Library(const QString &directory = {}, QObject *parent = nullptr);
    ~Library() override;

    int historyRevision() const { return m_historyRevision; }
    int bookmarksRevision() const { return m_bookmarksRevision; }
    int dialRevision() const { return m_dialRevision; }
    int downloadsRevision() const { return m_downloadsRevision; }
    QString directory() const { return m_directory; }

    // ---- History: one entry per address, with its last visit and a count.
    Q_INVOKABLE void visit(const QString &url, const QString &title);
    Q_INVOKABLE void updateTitle(const QString &url, const QString &title);
    // Newest first, filtered by words in the title or address.
    Q_INVOKABLE QVariantList history(const QString &query = {}, int limit = 300) const;
    // Best matches for the address bar: prefix of the site first, then by
    // how often and how recently it was visited.
    Q_INVOKABLE QVariantList suggest(const QString &query, int limit = 6) const;
    Q_INVOKABLE QVariantList topSites(int limit = 8) const;
    Q_INVOKABLE void removeHistory(const QString &url);
    // Removes visits made after `sinceMs` (0: everything).
    Q_INVOKABLE void clearHistory(double sinceMs = 0);
    Q_INVOKABLE int historyCount() const { return m_history.size(); }
    static bool recordable(const QString &url);

    // ---- Bookmarks: {url, title, folder, added}. The empty folder is the bar.
    Q_INVOKABLE bool isBookmarked(const QString &url) const;
    Q_INVOKABLE void addBookmark(const QString &url, const QString &title, const QString &folder = {});
    Q_INVOKABLE void removeBookmark(const QString &url);
    Q_INVOKABLE bool toggleBookmark(const QString &url, const QString &title);
    Q_INVOKABLE void editBookmark(const QString &url, const QString &title, const QString &newUrl, const QString &folder);
    Q_INVOKABLE void moveBookmark(int from, int to);
    Q_INVOKABLE QVariantList bookmarks(const QString &query = {}) const;
    Q_INVOKABLE QVariantMap bookmark(const QString &url) const;
    Q_INVOKABLE QStringList folders() const;
    // Chromium-family JSON ("Bookmarks") or a Netscape HTML export; returns
    // how many were added (duplicates are skipped).
    Q_INVOKABLE int importBookmarks(const QString &path);
    // Browsers whose bookmarks can be imported: [{name, path}].
    Q_INVOKABLE QVariantList importSources() const;
    Q_INVOKABLE bool exportBookmarks(const QString &path) const;

    // ---- Shortcuts on the new tab page.
    Q_INVOKABLE QVariantList dial() const;
    Q_INVOKABLE void addDial(const QString &url, const QString &title);
    Q_INVOKABLE void updateDial(int index, const QString &url, const QString &title);
    Q_INVOKABLE void removeDial(int index);
    Q_INVOKABLE void moveDial(int from, int to);
    Q_INVOKABLE bool inDial(const QString &url) const;

    // ---- Session: [{tabs: [{url, title, pinned}], current}] per window.
    Q_INVOKABLE void saveSession(const QVariantList &windows);
    Q_INVOKABLE QVariantList session() const;

    // ---- Zoom per site (by host). 0 means "use the default".
    Q_INVOKABLE double zoomFor(const QString &url) const;
    Q_INVOKABLE void setZoom(const QString &url, double factor);

    // ---- Finished downloads: {name, path, url, size, finished, ok}.
    Q_INVOKABLE void logDownload(const QVariantMap &download);
    Q_INVOKABLE QVariantList downloads() const;
    Q_INVOKABLE void removeDownload(const QString &path);
    Q_INVOKABLE void clearDownloads();

    Q_INVOKABLE void flush();

    static QString hostOf(const QString &url);
    // Lower-case, accents removed, for matching what is typed.
    static QString fold(const QString &text);

signals:
    void historyChanged();
    void bookmarksChanged();
    void dialChanged();
    void downloadsChanged();

private:
    QJsonArray load(const QString &name) const;
    void save(const QString &name, const QJsonArray &array) const;
    void schedule(const QString &name);
    int findHistory(const QString &url) const;
    int findBookmark(const QString &url) const;

    QString m_directory;
    QJsonArray m_history;
    QJsonArray m_bookmarks;
    QJsonArray m_dial;
    QJsonArray m_downloads;
    QHash<QString, double> m_zoom;
    QHash<QString, int> m_historyIndex;
    QStringList m_dirty;
    QTimer m_saveTimer;
    int m_historyRevision = 0;
    int m_bookmarksRevision = 0;
    int m_dialRevision = 0;
    int m_downloadsRevision = 0;
};
