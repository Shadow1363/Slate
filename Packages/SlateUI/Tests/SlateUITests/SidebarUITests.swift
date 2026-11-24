import Foundation
import SlateCore
@testable import SlateUI
import Testing

@Suite("Sidebar")
@MainActor
struct SidebarUITests {
    @Test func tabsFollowTheArea() {
        #expect(ProjectSession.SidebarTab.tabs(for: .script) == [.todos, .notes, .define])
        #expect(ProjectSession.SidebarTab.tabs(for: .universe) == [.todos, .links, .define])
        #expect(ProjectSession.SidebarTab.tabs(for: .dictionary) == [.links, .define])
        #expect(ProjectSession.SidebarTab.tabs(for: .storyboard) == [.links, .define])
    }

    @Test func eachAreaRemembersItsTabAndFallsBack() throws {
        defer { UserDefaults.standard.removeObject(forKey: ProjectSession.sidebarShownKey) }
        let session = try SessionHarness().session
        session.area = .script
        #expect(session.sidebarTab == .todos)
        session.sidebarTab = .notes
        session.area = .universe
        #expect(session.sidebarTab == .todos)
        session.sidebarTab = .links
        session.area = .dictionary
        // Links is offered here too, but this area hasn't picked one: its first tab.
        #expect(session.sidebarTab == .links)
        session.area = .script
        #expect(session.sidebarTab == .notes)
        // A tab the area doesn't have isn't kept.
        session.showSidebar(.links)
        #expect(session.sidebarTab == .notes)
        #expect(session.showingSidebar)
    }

    @Test func showTodosOpensThenHides() throws {
        defer { UserDefaults.standard.removeObject(forKey: ProjectSession.sidebarShownKey) }
        let session = try SessionHarness().session
        session.area = .universe
        session.showingSidebar = false
        session.toggleTodos()
        #expect(session.showingSidebar && session.sidebarTab == .todos)
        session.toggleTodos()
        #expect(!session.showingSidebar)
        session.sidebarTab = .define
        session.showingSidebar = true
        session.toggleTodos()
        #expect(session.showingSidebar && session.sidebarTab == .todos)
        // No to-dos in the Dictionary: it just shows or hides the sidebar.
        session.area = .dictionary
        session.toggleTodos()
        #expect(!session.showingSidebar)
    }

    @Test func searchResultsAndDefineOpenTheirTab() throws {
        defer { UserDefaults.standard.removeObject(forKey: ProjectSession.sidebarShownKey) }
        let session = try SessionHarness().session
        session.showingSidebar = false
        session.area = .universe
        session.open(.marginNote(sceneID: nil, quote: nil))
        #expect(session.area == .script && session.showingSidebar && session.sidebarTab == .notes)
        session.open(.todo(line: 0, sceneID: nil, quote: nil))
        #expect(session.sidebarTab == .todos)
        #expect(session.script.margin.scope == .all)
        session.defineSelection()
        #expect(session.sidebarTab == .define)
    }

    @Test func visibilityIsRemembered() throws {
        defer { UserDefaults.standard.removeObject(forKey: ProjectSession.sidebarShownKey) }
        let h = try SessionHarness()
        h.session.showingSidebar = false
        #expect(ProjectSession(store: h.store).showingSidebar == false)
        h.session.showingSidebar = true
        #expect(ProjectSession(store: h.store).showingSidebar)
    }
}
