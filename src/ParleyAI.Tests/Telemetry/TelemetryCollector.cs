using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using ParleyAI.Telemetry;

namespace ParleyAI.Tests.Telemetry;

/// <summary>
/// An in-process listener that captures the activities (spans) and metric measurements ParleyAI emits
/// on the named <see cref="ParleyAiTelemetry.ActivitySource"/> / <see cref="ParleyAiTelemetry.Meter"/>
/// — the test stand-in for an OTLP exporter (ParleyAI takes no exporter dependency itself).
/// </summary>
/// <remarks>
/// Subscribes to BOTH sources by their PUBLIC names (<see cref="ParleyAiTelemetry.ActivitySourceName"/>
/// / <see cref="ParleyAiTelemetry.MeterName"/>) — the same names a consumer registers — so a name drift
/// breaks these tests, asserting the documented contract. Dispose to stop listening.
/// </remarks>
internal sealed class TelemetryCollector : IDisposable
{
    // Correlates emitted telemetry to THIS collector's async-flow. EVERY provider call in the suite
    // emits on the process-global source/meter, so a collector listening by name alone would
    // cross-capture other concurrently-running test classes. Setting an AsyncLocal token in the ctor
    // (which flows into the awaited provider call on this test's async-flow) and comparing it in the
    // listener callbacks scopes capture to exactly this test, with no assembly-wide parallelism opt-out.
    private static readonly AsyncLocal<Guid> ActiveToken = new();

    private readonly Guid _token = Guid.NewGuid();
    private readonly ActivityListener _activityListener;
    private readonly MeterListener _meterListener;
    private readonly object _gate = new();

    internal TelemetryCollector()
    {
        ActiveToken.Value = _token;

        _activityListener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == ParleyAiTelemetry.ActivitySourceName,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = activity =>
            {
                if (ActiveToken.Value != _token)
                {
                    return;
                }

                lock (_gate)
                {
                    Activities.Add(activity);
                }
            },
        };
        ActivitySource.AddActivityListener(_activityListener);

        _meterListener = new MeterListener
        {
            InstrumentPublished = (instrument, listener) =>
            {
                if (instrument.Meter.Name == ParleyAiTelemetry.MeterName)
                {
                    lock (_gate)
                    {
                        PublishedInstruments.Add(instrument);
                    }

                    listener.EnableMeasurementEvents(instrument);
                }
            },
        };
        _meterListener.SetMeasurementEventCallback<double>((instrument, measurement, tags, _) =>
            RecordMeasurement(instrument, measurement, tags));
        _meterListener.SetMeasurementEventCallback<long>((instrument, measurement, tags, _) =>
            RecordMeasurement(instrument, measurement, tags));
        _meterListener.Start();
    }

    /// <summary>Every stopped activity (span) ParleyAI emitted while this collector was listening.</summary>
    internal List<Activity> Activities { get; } = new();

    /// <summary>Every instrument published on the ParleyAI meter (name + unit assertions).</summary>
    internal List<Instrument> PublishedInstruments { get; } = new();

    /// <summary>Every measurement recorded, with its instrument and the tag bag at record time.</summary>
    internal List<RecordedMeasurement> Measurements { get; } = new();

    private void RecordMeasurement(Instrument instrument, double value, ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        if (ActiveToken.Value != _token)
        {
            return;
        }

        var bag = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, object?> tag in tags)
        {
            bag[tag.Key] = tag.Value;
        }

        lock (_gate)
        {
            Measurements.Add(new RecordedMeasurement(instrument.Name, instrument.Unit, value, bag));
        }
    }

    public void Dispose()
    {
        ActiveToken.Value = Guid.Empty;
        _meterListener.Dispose();
        _activityListener.Dispose();
    }

    /// <summary>A single recorded metric measurement: instrument name + unit + value + tags.</summary>
    internal sealed record RecordedMeasurement(
        string InstrumentName,
        string? Unit,
        double Value,
        IReadOnlyDictionary<string, object?> Tags);
}
