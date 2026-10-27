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
    serviceIds: ['google', 'youtube'],
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
  ServiceGroup(
    id: 'copilot-group',
    displayName: 'Microsoft Copilot',
    serviceIds: ['copilot'],
  ),
  ServiceGroup(
    id: 'meta-ai-group',
    displayName: 'Meta AI',
    serviceIds: ['meta-ai'],
  ),
  ServiceGroup(id: 'grok-group', displayName: 'Grok', serviceIds: ['grok']),
  ServiceGroup(
    id: 'perplexity-group',
    displayName: 'Perplexity',
    serviceIds: ['perplexity'],
  ),
  ServiceGroup(
    id: 'mistral-group',
    displayName: 'Mistral',
    serviceIds: ['mistral'],
  ),
  ServiceGroup(id: 'poe-group', displayName: 'Poe', serviceIds: ['poe']),
  ServiceGroup(
    id: 'disney-group',
    displayName: 'Disney+',
    serviceIds: ['disney'],
  ),
  ServiceGroup(
    id: 'appletv-group',
    displayName: 'Apple TV+',
    serviceIds: ['appletv'],
  ),
  ServiceGroup(
    id: 'gemini-group',
    displayName: 'Gemini',
    serviceIds: ['gemini'],
  ),
  ServiceGroup(id: 'muse-group', displayName: 'Muse', serviceIds: ['muse']),
];

ServiceGroup? groupForService(String serviceId) {
  for (final group in defaultServiceGroups) {
    if (group.serviceIds.contains(serviceId)) {
      return group;
    }
  }
  return null;
}
