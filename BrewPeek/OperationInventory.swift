import Foundation

/// A completed operation keeps its results even when refreshing the inventory fails.
enum OperationInventory {
  static func append(
    to result: inout Record, inventory: Inventory, destination: URL,
    invalidatingSizes: Set<String>
  ) {
    do {
      let snapshot = try inventory.collect(
        refreshMetadata: false, previous: try? InventoryStore.load(destination),
        invalidatingSizes: invalidatingSizes)
      try InventoryStore.save(snapshot, to: destination)
      result["snapshot"] = InventoryStore.displaySnapshot(snapshot)
    } catch { result["refreshError"] = error.localizedDescription }
  }
}
