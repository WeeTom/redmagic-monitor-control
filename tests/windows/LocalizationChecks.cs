using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using RedMagicMonitor;

internal static class LocalizationChecks
{
    internal static void Run()
    {
        Check(L.MatchLanguage(["nl-NL", "fr-CA", "en-US"]) == "fr", "ordered system preferences");
        Check(L.MatchLanguage(["zh-Hant-CN"]) == "zh-Hant" && L.MatchLanguage(["zh-Hans-HK"]) == "zh-Hans",
            "explicit Chinese script takes precedence over region");
        Check(L.MatchLanguage(["zh-TW"]) == "zh-Hant" && L.MatchLanguage(["zh-HK"]) == "zh-Hant" &&
            L.MatchLanguage(["zh-MO"]) == "zh-Hant" && L.MatchLanguage(["zh-SG"]) == "zh-Hans",
            "Chinese regional defaults");
        Check(L.MatchLanguage(["nl-NL", "it-IT"]) == "en" && L.MatchLanguage([]) == "en", "English fallback");

        var english = Read("en");
        foreach (var locale in new[] { "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "ru", "fr", "de", "pt" })
        {
            L.UseSystemLanguages([locale]);
            var table = locale == "zh-Hans" ? english.ToDictionary(pair => pair.Key, pair => pair.Key) : Read(locale);
            Check(table.Count == english.Count && english.Keys.All(table.ContainsKey), $"{locale} catalog keys");
            foreach (var (key, value) in table)
            {
                if (string.IsNullOrWhiteSpace(value) || L.T(key) != value || !Fields(key).SequenceEqual(Fields(value)))
                    throw new InvalidDataException($"Invalid localization for '{key}' in {locale}");
            }
            Check(L.T("Windows 快捷方式 (*.lnk)|*.lnk").EndsWith("(*.lnk)|*.lnk", StringComparison.Ordinal) &&
                L.T("红魔显示器 - {0}.lnk", "HDMI 1").EndsWith("HDMI 1.lnk", StringComparison.Ordinal),
                $"{locale} shell-link export");
            Check(L.T("读取 VCP 0x{0:X2} 失败 {1}", 10, "error").Contains("0x0A") &&
                L.T("¥{0:N2}", 6.66m).Contains(6.66m.ToString("N2", CultureInfo.CurrentCulture)),
                $"{locale} localized formatted values");
        }
        var originalRegion = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("fr-FR");
            L.UseSystemLanguages(["ja-JP"]);
            Check(L.T("¥{0:N2}", 6.66m).Contains("6,66"), "number format follows region independently of UI language");
        }
        finally
        {
            CultureInfo.CurrentCulture = originalRegion;
            L.UseSystemLanguages([CultureInfo.CurrentUICulture.Name]);
        }
    }

    private static Dictionary<string, string> Read(string locale)
    {
        using var stream = typeof(L).Assembly.GetManifestResourceStream($"Locales.{locale}.json")!;
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)!;
    }

    private static IEnumerable<string> Fields(string text) =>
        Regex.Matches(text, @"\{\d+(?::[^{}]+)?\}").Select(match => match.Value).Order(StringComparer.Ordinal);

    private static void Check(bool ok, string test)
    {
        if (!ok) throw new InvalidDataException("Localization: " + test);
        Console.WriteLine("PASS localization " + test);
    }
}
