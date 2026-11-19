using System;
using System.Windows.Markup;

namespace RedMagicMonitor;

[MarkupExtensionReturnType(typeof(string))]
public sealed class TrExtension : MarkupExtension
{
    public string Key { get; set; } = "";
    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(Key);
}
