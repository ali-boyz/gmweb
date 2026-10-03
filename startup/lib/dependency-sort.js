export function topologicalSort(services) {
  const visited = new Set();
  const sorted = [];
  const visiting = new Set();

  const visit = (name) => {
    if (visited.has(name)) return true;
    if (visiting.has(name)) return false;
    visiting.add(name);
    const service = services.get(name);
    if (!service) {
      console.error(`[topologicalSort] Service '${name}' not found in services map`);
      visiting.delete(name);
      return true;
    }
    if (service.dependencies && Array.isArray(service.dependencies)) {
      for (const dep of service.dependencies) {
        if (!visit(dep)) return false;
      }
    }
    visiting.delete(name);
    visited.add(name);
    sorted.push(service);
    return true;
  };

  for (const [name] of services) {
    if (!visit(name)) return null;
  }
  return sorted;
}

export function groupByDependency(sorted, logger) {
  const groups = [];
  const serviceToGroup = new Map();

  for (const service of sorted) {
    if (!service || !service.name) {
      console.error('[groupByDependency] Skipping invalid service entry:', service);
      continue;
    }
    
    let groupIndex = 0;
    if (service.dependencies && Array.isArray(service.dependencies) && service.dependencies.length > 0) {
      for (const dep of service.dependencies) {
        const depGroup = serviceToGroup.get(dep);
        if (depGroup !== undefined) {
          groupIndex = Math.max(groupIndex, depGroup + 1);
        }
      }
    }
    serviceToGroup.set(service.name, groupIndex);
    if (!groups[groupIndex]) groups[groupIndex] = [];
    groups[groupIndex].push(service);
  }

  if (logger) {
    logger.log('INFO', `Organized ${sorted.length} services into ${groups.length} parallel groups`);
    groups.forEach((group, idx) => {
      logger.log('INFO', `  Group ${idx + 1}: ${group.map(s => s.name).join(', ')}`);
    });
  }

  return groups;
}
