import AppKit
import AtriumCore

/// Naming a voice as somebody the roster may or may not already have.
///
/// This was an `NSAlert` with a single name field, and the duplicate
/// check ran *after* it closed as a second modal — so the user typed a
/// name, pressed Create, and only then found out the person already
/// existed. The search that would have told them was in a different
/// window entirely.
///
/// Now typing is the search. Matches appear as they are typed, and an
/// exact one says so in place rather than in a dialog on top of a
/// dialog. Pressing Create with a warning on screen is then a decision
/// rather than a surprise.
///
/// ## Why an inline warning and not a second confirmation
///
/// A duplicate person is a real mess — Atrium PA disambiguates by
/// appending the older person's id, and that voice's history is then
/// split across two records that must be merged by hand. But the person
/// pressing Create has just read who already exists and chosen anyway.
/// Asking twice is nagging; the job is to make sure they were told
/// *before* they decided.
final class NewPersonSheet: NSWindow, NSTextFieldDelegate {

    enum Outcome {
        /// Somebody the roster already has.
        case use(personID: Int, name: String)
        case create(name: String, email: String?)
        case cancel
    }

    private var client: MCPClient?
    private var completion: ((Outcome) -> Void)?

    /// What the last search returned, parallel to `matches` after its
    /// first item.
    private var found: [MCPClient.Person] = []
    /// Bumped per keystroke so a slow response cannot overwrite a newer
    /// one — the field is searched on every character, and replies do
    /// not necessarily arrive in the order they were asked for.
    private var searchGeneration = 0

    private let nameField = NSTextField()
    private let emailField = NSTextField()
    private let searchButton = NSButton()
    private let matches = NSPopUpButton()
    private let warning = NSTextField(labelWithString: "")
    private let useExisting = NSButton()
    private let createButton = NSButton()
    private let spinner = NSProgressIndicator()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Who is this?"
        isReleasedWhenClosed = false
        buildContent()
    }

    func present(on host: NSWindow, client: MCPClient, completion: @escaping (Outcome) -> Void) {
        self.client = client
        self.completion = completion
        nameField.stringValue = ""
        emailField.stringValue = ""
        matches.removeAllItems()
        matches.addItem(withTitle: "No match yet")
        matches.isEnabled = false
        warning.stringValue = ""
        useExisting.isHidden = true
        createButton.isEnabled = false
        searchButton.isEnabled = false
        found = []
        host.beginSheet(self)
        makeFirstResponder(nameField)
    }

    private func finish(_ outcome: Outcome) {
        let completion = self.completion
        self.completion = nil
        sheetParent?.endSheet(self)
        completion?(outcome)
    }

    override func cancelOperation(_ sender: Any?) { finish(.cancel) }

    /// Closing by the title bar's X is a cancel. Without this the
    /// completion is never called and the row it came from sits with a
    /// selection it never applied.
    override func close() {
        if completion != nil { finish(.cancel) } else { super.close() }
    }

    // MARK: - Searching as you type

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === nameField else { return }
        search()
    }

    @objc private func searchNow() { search() }

    private func search() {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        createButton.isEnabled = !typed.isEmpty
        searchButton.isEnabled = typed.count >= 2
        warning.stringValue = ""
        useExisting.isHidden = true

        // Two characters is the floor the client enforces anyway; below
        // it a search returns most of the address book.
        guard typed.count >= 2, let client else {
            matches.removeAllItems()
            matches.addItem(withTitle: "No match yet")
            matches.isEnabled = false
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        spinner.startAnimation(nil)
        Task { [weak self] in
            var people: [MCPClient.Person] = []
            do {
                people = try await client.searchPeople(matching: typed)
            } catch {
                // Fail open, and say so. The check exists to prevent a
                // mess, not to become a new way for the work to fail —
                // but a duplicate created while the roster was
                // unreachable should be explicable afterwards.
                Log.write(
                    "naming: could not search for “\(typed)” (\(error)) — "
                        + "a duplicate cannot be detected right now")
            }
            onMainThread {
                guard let self, generation == self.searchGeneration else { return }
                self.spinner.stopAnimation(nil)
                self.show(people, for: typed)
            }
        }
    }

    private func show(_ people: [MCPClient.Person], for typed: String) {
        found = people
        matches.removeAllItems()
        if people.isEmpty {
            matches.addItem(withTitle: "Nobody found — this will be a new person")
            matches.isEnabled = false
        } else {
            matches.addItem(withTitle: "Create a new person")
            matches.lastItem?.representedObject = nil
            for person in people {
                matches.addItem(withTitle: person.label)
                matches.lastItem?.representedObject = person.id
            }
            matches.isEnabled = true
        }

        // An exact match is the one worth interrupting for. A merely
        // similar name is offered in the list and nothing more — see
        // `PersonMatch` for why this is deliberately not fuzzy.
        let duplicates = PersonMatch.duplicates(of: typed, in: people)
        guard let first = duplicates.first else { return }
        warning.stringValue =
            duplicates.count == 1
            ? "Atrium PA already knows \(first.label). Creating a second one "
                + "splits this voice's history across both."
            : "Atrium PA already knows \(duplicates.count) people with this name."
        useExisting.title = "Use \(first.displayName)"
        useExisting.isHidden = false
        useExisting.tag = first.id
    }

    // MARK: - Actions

    @objc private func pickMatch() {
        guard let personID = matches.selectedItem?.representedObject as? Int,
            let person = found.first(where: { $0.id == personID })
        else { return }
        finish(.use(personID: person.id, name: person.displayName))
    }

    @objc private func useExistingTapped() {
        guard let person = found.first(where: { $0.id == useExisting.tag }) else { return }
        finish(.use(personID: person.id, name: person.displayName))
    }

    @objc private func create() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        finish(.create(name: name, email: email.isEmpty ? nil : email))
    }

    @objc private func cancel() { finish(.cancel) }

    // MARK: - Layout

    private func buildContent() {
        let view = NSView()

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            field.textColor = .secondaryLabelColor
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
            return field
        }

        let blurb = NSTextField(
            labelWithString:
                "Type a name to search Atrium PA. Anyone already there appears "
                + "below — naming a voice as an existing person keeps their "
                + "history together.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.lineBreakMode = .byWordWrapping
        blurb.maximumNumberOfLines = 3
        // Without this a wrapping label reports its intrinsic width as
        // the whole sentence on one line, and the window grows to fit —
        // which is why this dialog opened three times wider than it was
        // asked to be.
        blurb.preferredMaxLayoutWidth = 400
        blurb.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "Full name"
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        // Typing already searches. This is for the times that is not
        // enough: a search that failed while the network was down, a
        // name pasted in rather than typed — `controlTextDidChange`
        // does not fire for every way text can arrive in a field — or
        // simply wanting to be sure it looked.
        searchButton.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchButton.bezelStyle = .rounded
        searchButton.toolTip = "Search Atrium PA for this name"
        searchButton.target = self
        searchButton.action = #selector(searchNow)
        searchButton.translatesAutoresizingMaskIntoConstraints = false

        // Optional, and said so. An email is what lets Atrium PA join
        // this person to their mail and calendar, so it is worth asking
        // for — and worth not demanding, because often nobody knows it.
        emailField.placeholderString = "Email (optional)"
        emailField.translatesAutoresizingMaskIntoConstraints = false

        matches.target = self
        matches.action = #selector(pickMatch)
        matches.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        warning.lineBreakMode = .byWordWrapping
        warning.maximumNumberOfLines = 3
        warning.preferredMaxLayoutWidth = 330
        warning.translatesAutoresizingMaskIntoConstraints = false

        useExisting.bezelStyle = .rounded
        useExisting.target = self
        useExisting.action = #selector(useExistingTapped)
        useExisting.translatesAutoresizingMaskIntoConstraints = false

        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        createButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton()
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = label("Name")
        let emailLabel = label("Email")
        let matchLabel = label("Matches")
        for subview in [
            blurb, nameLabel, nameField, searchButton, emailLabel, emailField,
            matchLabel, matches, spinner, warning, useExisting, createButton,
            cancelButton,
        ] { view.addSubview(subview) }

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 440),

            blurb.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            blurb.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            blurb.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            nameLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(
                equalTo: searchButton.leadingAnchor, constant: -6),
            nameField.topAnchor.constraint(equalTo: blurb.bottomAnchor, constant: 14),
            searchButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -20),
            searchButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: 34),

            emailLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            emailLabel.centerYAnchor.constraint(equalTo: emailField.centerYAnchor),
            emailField.leadingAnchor.constraint(equalTo: emailLabel.trailingAnchor, constant: 8),
            emailField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            emailField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),

            matchLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            matchLabel.centerYAnchor.constraint(equalTo: matches.centerYAnchor),
            matches.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 8),
            matches.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            matches.topAnchor.constraint(equalTo: emailField.bottomAnchor, constant: 10),
            spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: matches.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),

            warning.leadingAnchor.constraint(equalTo: matches.leadingAnchor),
            warning.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            warning.topAnchor.constraint(equalTo: matches.bottomAnchor, constant: 8),

            useExisting.leadingAnchor.constraint(equalTo: matches.leadingAnchor),
            useExisting.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 6),

            // Below whatever the warning grew to, and the bottom of
            // the window follows it — rather than a fixed height with
            // an empty band in the middle.
            createButton.topAnchor.constraint(
                greaterThanOrEqualTo: useExisting.bottomAnchor, constant: 16),
            createButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            createButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            createButton.widthAnchor.constraint(equalToConstant: 90),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 90),
        ])
        contentView = view
    }
}
