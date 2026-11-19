using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace RedMagicMonitor;

internal static class MonitorDiscovery
{
    internal const string Model = "REDMAGIC GM001J";

    internal static bool TryAddress(string? text, out ulong address)
    {
        address = 0;
        var hex = text?.Trim().Replace(":", "").Replace("-", "");
        return hex?.Length == 12 && ulong.TryParse(hex, NumberStyles.AllowHexSpecifier,
            CultureInfo.InvariantCulture, out address) && address is > 0 and < 0xffffffffffff;
    }

    // Firmware appends the six-byte FFD2 identity to its advertised model name.
    // Device/scan-response names may appear without the suffix.
    internal static bool ModelName(string? text, out ulong? identity)
    {
        identity = null;
        var name = text?.Trim();
        if (string.Equals(name, Model, StringComparison.OrdinalIgnoreCase)) return true;
        if (name?.Length != Model.Length + 12 || !name.StartsWith(Model, StringComparison.OrdinalIgnoreCase) ||
            !TryAddress(name[Model.Length..], out ulong address)) return false;
        identity = address;
        return true;
    }

    internal static string FormatAddress(ulong address) =>
        string.Join(":", Enumerable.Range(0, 6).Select(i => ((address >> (40 - i * 8)) & 255).ToString("X2", CultureInfo.InvariantCulture)));

    internal static bool ValidIdentity(byte[] value, ulong? advertised, ulong? cached, ulong transportAddress)
    {
        if (value.Length != 6) return false;
        ulong identity = 0;
        foreach (var b in value) identity = (identity << 8) | b;
        if (identity is 0 or 0xffffffffffff || (advertised.HasValue && advertised != identity) ||
            (cached.HasValue && cached != identity)) return false;
        // Address-bearing names work even if the on-air address is private.
        // A bare model name or service hint must corroborate FFD2 against the device address.
        return advertised.HasValue || cached.HasValue || identity == transportAddress;
    }
}

internal sealed record BleCandidate(ulong Address, string? DeviceId, string Name, ulong? ClaimedIdentity,
    bool AdvertisedService, bool? RandomAddress)
{
    internal string Label => $"{MonitorDiscovery.Model} · {MonitorDiscovery.FormatAddress(ClaimedIdentity ?? Address)}";

    internal static List<BleCandidate> Merge(IEnumerable<BleCandidate> candidates) =>
        candidates.GroupBy(c => c.Address).Select(group =>
        {
            var live = group.FirstOrDefault(c => c.RandomAddress.HasValue) ?? group.First();
            var named = group.FirstOrDefault(c => c.ClaimedIdentity.HasValue) ??
                group.FirstOrDefault(c => MonitorDiscovery.ModelName(c.Name, out _)) ?? live;
            return live with { Name = named.Name, ClaimedIdentity = named.ClaimedIdentity,
                DeviceId = group.FirstOrDefault(c => c.DeviceId != null)?.DeviceId,
                AdvertisedService = group.Any(c => c.AdvertisedService) };
        }).OrderBy(c => c.Label, StringComparer.Ordinal).ToList();
}
