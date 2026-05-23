//
//  WorldClockMenuActionHandler.swift
//  MenuShelf
//
//  Helper invoked from `MenuActionHandler.execute(_:modifierFlags:)` when
//  the `.openWorldClock` action fires. Resolves the originating menu
//  view's status button anchor and dispatches the popover toggle on the
//  controller (or opens the settings pane when the feature is disabled).
//

import AppKit
import Foundation
