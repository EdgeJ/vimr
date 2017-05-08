/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import RxSwift

class FileItemUtils {

  static func flatFileItems(of url: URL,
                            ignorePatterns: Set<FileItemIgnorePattern>,
                            ignoreToken: Token,
                            root: FileItem) -> Observable<[FileItem]> {
    guard url.isFileURL else {
      return Observable.empty()
    }

    guard FileUtils.fileExists(at: url) else {
      return Observable.empty()
    }

    let pathComponents = url.pathComponents
    return Observable.create { observer in
      let cancel = Disposables.create {
        // noop
      }

      scanDispatchQueue.async {
        guard let targetItem = fileItem(for: pathComponents, root: root) else {
          observer.onCompleted()
          return
        }

        var flatNewFileItems: [FileItem] = []

        var dirStack: [FileItem] = [targetItem]
        while let curItem = dirStack.popLast() {
          if cancel.isDisposed {
            observer.onCompleted()
            return
          }

          if !curItem.childrenScanned || curItem.needsScanChildren {
            scanChildren(curItem)
          }

          curItem.children
            .filter { item in
              if item.isHidden || item.isPackage {
                return false
              }

              // This item already has been fnmatch'ed, thus return the cached value.
              if item.ignoreToken == ignoreToken {
                return !item.ignore
              }

              item.ignoreToken = ignoreToken
              item.ignore = false

              let path = item.url.path
              for pattern in ignorePatterns {
                // We don't use `String.FnMatchOption.leadingDir` (`FNM_LEADING_DIR`) for directories since we do not
                // scan ignored directories at all when filtering. For example "*/.git" would create a `FileItem`
                // for `/some/path/.git`, but not scan its children when we filter.
                if pattern.match(absolutePath: path) {
                  item.ignore = true
                  return false
                }
              }

              return true
            }
            .forEach { $0.isDir ? dirStack.append($0) : flatNewFileItems.append($0) }

          if flatNewFileItems.count >= emitChunkSize {
            observer.onNext(flatNewFileItems)
            flatNewFileItems = []
          }
        }

        if !cancel.isDisposed {
          observer.onNext(flatNewFileItems)
          observer.onCompleted()
        }
      }

      return cancel
    }
  }

  static func item(for url: URL, root: FileItem, create: Bool = true) -> FileItem? {
    return fileItem(for: url.pathComponents, root: root, create: create)
  }

  static func sortedChildren(for url: URL, root: FileItem) -> [FileItem] {
    guard let fileItem = fileItem(for: url, root: root) else {
      return []
    }

    if !fileItem.childrenScanned || fileItem.needsScanChildren {
      scanChildren(fileItem, sorted: true)
      return fileItem.children
    }

    return fileItem.children.sorted()
  }
}

/// When at least this much of non-directory and visible files are scanned, they are emitted.
fileprivate let emitChunkSize = 1000
fileprivate let scanDispatchQueue = DispatchQueue.global(qos: .userInitiated)
fileprivate var spinLock = OS_SPINLOCK_INIT

fileprivate func syncAddChildren(_ fn: () -> Void) {
  OSSpinLockLock(&spinLock)
  fn()
  OSSpinLockUnlock(&spinLock)
}

fileprivate func fileItem(for pathComponents: [String], root: FileItem, create: Bool = true) -> FileItem? {
  let result = pathComponents.dropFirst().reduce(root) { (resultItem, childName) -> FileItem? in
    guard let parent = resultItem else {
      return nil
    }

    return child(withName: childName, ofParent: parent, create: true)
  }

  return result
}

fileprivate func fileItem(for url: URL, root: FileItem, create: Bool = true) -> FileItem? {
  return fileItem(for: url.pathComponents, root: root, create: create)
}

/// Even when the result is nil it does not mean that there's no child with the given name. It could well be that
/// it's not been scanned yet. However, if `create` parameter was true and `nil` is returned, the requested
/// child does not exist.
///
/// - parameters:
///   - name: name of the child to get.
///   - parent: parent of the child.
///   - create: whether to create the child `FileItem` if it's not scanned yet.
/// - returns: child `FileItem` or nil.
fileprivate func child(withName name: String, ofParent parent: FileItem, create: Bool = false) -> FileItem? {
  let filteredChildren = parent.children.filter { $0.url.lastPathComponent == name }

  if filteredChildren.isEmpty && create {
    let childUrl = parent.url.appendingPathComponent(name)

    guard FileUtils.fileExists(at: childUrl) else {
      return nil
    }

    let child = FileItem(childUrl)
    syncAddChildren { parent.children.append(child) }

    return child
  }

  return filteredChildren.first
}

fileprivate func scanChildren(_ item: FileItem, sorted: Bool = false) {
  let children = FileUtils.directDescendants(of: item.url).map(FileItem.init)
  syncAddChildren {
    if sorted {
      item.children = children.sorted()
    } else {
      item.children = children
    }
  }

  item.childrenScanned = true
  item.needsScanChildren = false
}
