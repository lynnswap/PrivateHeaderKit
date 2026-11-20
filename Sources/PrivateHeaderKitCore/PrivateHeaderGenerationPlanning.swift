import Foundation
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitSourceInspection

extension PrivateHeaderGeneration.GenerationExecutor {
  static func preparePlan(
    _ plan: PrivateHeaderGeneration.Plan,
    sharedCacheInventoryRunner: SharedCacheInventoryRunner
  ) async throws -> PreparedPlan {
    guard let systemRoot = plan.options.systemRoot else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("systemRoot")
    }
    guard let helperURLs = plan.options.helperURLs else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("helperURLs")
    }
    guard let executionMode = plan.options.executionMode else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
    }

    let sharedCacheCohort: SharedCacheCohort?
    if plan.options.rawDumpingOptions.useSharedCache {
      sharedCacheCohort = try await loadSharedCacheCohort(
        helperURLs: helperURLs,
        executionMode: executionMode,
        expectedProducerVersion: plan.options.producerVersion,
        helperEnvironment: plan.options.rawDumpingOptions.helperEnvironment,
        sharedCacheInventoryRunner: sharedCacheInventoryRunner
      )
    } else {
      sharedCacheCohort = nil
    }

    let catalog: TargetDiscovery.Catalog
    if let application = plan.options.applicationSource {
      catalog = try application.catalog()
    } else if case .ssh = executionMode {
      guard let deviceSource = plan.options.deviceSource else {
        throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("deviceSource")
      }
      if let sharedCacheCohort, sharedCacheCohort.cacheUUID != deviceSource.cacheUUID {
        throw PrivateHeaderGeneration.GenerationError.deviceCacheChanged(
          expected: deviceSource.cacheUUID, actual: sharedCacheCohort.cacheUUID
        )
      }
      catalog = try deviceSource.catalog()
    } else {
      catalog = try TargetDiscovery.discover(
        in: systemRoot,
        sharedCacheImagePaths: sharedCacheCohort?.imagePaths ?? []
      )
    }
    let selectedTargets = try selectedExecutionTargets(
      request: plan.options.targetRequest,
      catalog: catalog
    )
    guard !selectedTargets.isEmpty else {
      throw PrivateHeaderGeneration.GenerationError.noDiscoveredTargets(
        systemRoot: systemRoot.path
      )
    }
    return PreparedPlan(
      plan: plan,
      selectedTargets: selectedTargets,
      sharedCacheCohort: sharedCacheCohort
    )
  }

  fileprivate static func loadSharedCacheCohort(
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    expectedProducerVersion: String,
    helperEnvironment: [String: String],
    sharedCacheInventoryRunner: SharedCacheInventoryRunner
  ) async throws -> SharedCacheCohort {
    try Task.checkCancellation()
    let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
      helperURLs: helperURLs,
      executionMode: executionMode,
      helperEnvironment: helperEnvironment
    )
    let data = try await sharedCacheInventoryRunner(invocation)
    try Task.checkCancellation()
    let inventory = try JSONDecoder().decode(
      PrivateHeaderKitSharedCacheInventory.self,
      from: data
    )
    guard inventory.producerVersion == expectedProducerVersion else {
      throw PrivateHeaderGeneration.GenerationError.producerVersionMismatch(
        expected: expectedProducerVersion,
        actual: inventory.producerVersion
      )
    }
    guard !inventory.imagePaths.isEmpty else {
      throw PrivateHeaderGeneration.GenerationError.emptySharedCacheInventory(
        cacheUUID: inventory.cacheUUID
      )
    }
    return SharedCacheCohort(inventory)
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate static func selectedExecutionTargets(
    request: PrivateHeaderGeneration.TargetRequest,
    catalog: TargetDiscovery.Catalog
  ) throws -> [TargetDiscovery.DiscoveredTarget] {
    switch request {
    case .allAvailable:
      return deduplicated(catalog.allExecutionTargets)
    case .query(let query):
      let targetQuery = try PrivateHeaderGeneration.TargetQuery(commaSeparated: query)
      let resolution = catalog.resolver.resolve(targetQuery)
      switch resolution {
      case .selected(.allAvailable):
        return deduplicated(catalog.allExecutionTargets)
      case .selected(.targets(let candidates)):
        return deduplicated(
          candidates.flatMap { candidate in
            expandTarget(identifier: candidate.identifier, catalog: catalog)
          })
      case .needsDisambiguation, .failed, .unresolved:
        throw PrivateHeaderGeneration.GenerationError.unresolvedTargetQuery(resolution)
      }
    }
  }

  fileprivate static func expandTarget(
    identifier: String,
    catalog: TargetDiscovery.Catalog
  ) -> [TargetDiscovery.DiscoveredTarget] {
    for group in catalog.groups where group.selectionCandidate.identifier == identifier {
      return group.executionTargets
    }
    return []
  }

  fileprivate static func deduplicated(
    _ targets: [TargetDiscovery.DiscoveredTarget]
  ) -> [TargetDiscovery.DiscoveredTarget] {
    var seen: Set<String> = []
    return targets.filter { seen.insert($0.candidate.identifier).inserted }
  }
}
