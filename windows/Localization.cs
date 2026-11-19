using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace RedMagicMonitor;

internal static class L
{
    private static IReadOnlyDictionary<string, string> _strings = new Dictionary<string, string>();
    internal static string Language { get; private set; } = "zh-Hans";

    internal static string MatchLanguage(IEnumerable<string> preferences)
    {
        foreach (var tag in preferences)
        {
            string[] parts = tag.Replace('_', '-').ToLowerInvariant().Split('-');
            if (parts[0] == "zh")
            {
                // An explicit script takes priority over a conflicting region.
                if (Array.IndexOf(parts, "hant") >= 0) return "zh-Hant";
                if (Array.IndexOf(parts, "hans") >= 0) return "zh-Hans";
                return Array.Exists(parts, p => p is "tw" or "hk" or "mo" or "cht") ? "zh-Hant" : "zh-Hans";
            }
            if (parts[0] is "en" or "ja" or "ko" or "es" or "ru" or "fr" or "de" or "pt") return parts[0];
        }
        return "en";
    }

    internal static void UseSystemLanguages(IEnumerable<string> preferences)
    {
        string language = MatchLanguage(preferences);
        using var stream = typeof(L).Assembly.GetManifestResourceStream($"Locales.{language}.json");
        _strings = language == "zh-Hans" ? new Dictionary<string, string>()
            : JsonSerializer.Deserialize<Dictionary<string, string>>(
                stream ?? throw new InvalidOperationException($"Missing language resource: {language}"))!;
        Language = language;
    }

    internal static string T(string key, params object?[] arguments)
    {
        string text = _strings.TryGetValue(key, out var translation) ? translation : key;
        return arguments.Length == 0 ? text : string.Format(CultureInfo.CurrentCulture, text, arguments);
    }
}
