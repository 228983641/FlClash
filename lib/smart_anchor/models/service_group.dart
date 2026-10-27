class ServiceGroup {
  const ServiceGroup({
    required this.id,
    required this.displayName,
    required this.serviceIds,
  });

  final String id;
  final String displayName;
  final List<String> serviceIds;
}

const List<ServiceGroup> defaultServiceGroups = [
  ServiceGroup(
    id: 'google-group',
    displayName: 'Google',
    serviceIds: ['google', 'youtube', 'gemini'],
  ),
  ServiceGroup(
    id: 'openai-group',
    displayName: 'OpenAI',
    serviceIds: ['openai'],
  ),
  ServiceGroup(
    id: 'anthropic-group',
    displayName: 'Anthropic',
    serviceIds: ['claude'],
  ),
  ServiceGroup(
    id: 'cloudflare-group',
    displayName: 'Cloudflare',
    serviceIds: ['cloudflare'],
  ),
  ServiceGroup(
    id: 'netflix-group',
    displayName: 'Netflix',
    serviceIds: ['netflix'],
  ),
  ServiceGroup(id: 'x-group', displayName: 'X', serviceIds: ['x']),
];

ServiceGroup? groupForService(String serviceId) {
  for (final group in defaultServiceGroups) {
    if (group.serviceIds.contains(serviceId)) {
      return group;
    }
  }
  return null;
}
