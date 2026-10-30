//
//  Logging.swift
//  LittleRoute
//
//  Where the diagnostics go, now that they no longer go to print.
//
//  print writes to stdout, which on a device means the line exists only while
//  Xcode is attached and is gone the moment it isn't. Every one of the lines
//  this file's loggers now carry was written to answer a question that shows up
//  in the field — why is there silence, why did the context not switch, why is
//  the library empty after an update — and none of those questions get asked
//  while a debugger is running. Logger persists, is filterable, and survives the
//  session; that is the whole of the change.
//

import Foundation
import os

// MARK: - Loggers

// One logger per category, declared here rather than constructed at the call
// site. Loggers are cheap to make, so this is not about allocation: it is that a
// category is only worth having if every line that belongs to it spells it the
// same way, and a string literal repeated at forty-eight call sites will not
// stay spelled the same way. Filtering in Console.app is the entire feature, and
// one typo silently removes a line from the filter that was supposed to find it.
enum Log {
    // The bundle identifier, which is what the subsystem field is for and what
    // Console.app's process filter will already be showing.
    private static let subsystem = "nemphos.LittleRoute"

    // The categories are drawn along the lines the *failures* fall along, not
    // along file boundaries — the question a category has to answer is "I am
    // debugging this symptom, which lines do I want to see", and a symptom
    // rarely respects a file.
    //
    // Two of them come out of AudioPlayerManager alone, and that split is the
    // one worth justifying. Playback fails against AVAudioSession and the queue,
    // in real time, usually because something else on the device took the
    // session or because a context left nothing to play. The library fails
    // against the filesystem and SwiftData, at import time, because a copy or a
    // save didn't happen. They share a file and nothing else: different clocks,
    // different frameworks, different fixes. Someone chasing "the music stopped
    // when a call came in" wants none of the import chatter, and someone chasing
    // "I imported a song and it isn't there" wants none of the transport
    // chatter.
    //
    // For the same reason `library` and `migration` are separate despite both
    // being about songs in a store. Migration runs once, ever, on a version
    // change, and its failures are historical — they explain a library that was
    // already wrong when the app opened. Library failures are live. Reading them
    // interleaved would suggest a causal relationship between two things that
    // happened weeks apart.

    // AVAudioSession, interruptions, route changes, and the transport itself.
    static let playback = Logger(subsystem: subsystem, category: "playback")

    // Getting songs into the store and onto disk: the bundled catalogue at first
    // launch, and user imports thereafter.
    static let library = Logger(subsystem: subsystem, category: "library")

    // CoreLocation authorization and delivery failures.
    static let location = Logger(subsystem: subsystem, category: "location")

    // The detector: which context won, and the POI searches it does or doesn't buy.
    static let context = Logger(subsystem: subsystem, category: "context")

    // WeatherKit, which is mostly a provisioning story — see WeatherProvider.
    static let weather = Logger(subsystem: subsystem, category: "weather")

    // The schema migration stages, which run once per version bump and never again.
    static let migration = Logger(subsystem: subsystem, category: "migration")

    // MARK: - Signposts

    // Intervals around POI searches, so the cost of location polling can be read
    // off a trace rather than guessed at. Kept beside the loggers because it
    // shares the subsystem and is the same kind of thing: a diagnostic surface
    // that has to be spelled identically everywhere to be worth anything.
    //
    // The category here is a plain descriptive string, which means the intervals
    // show up under the os_signpost instrument once it is pointed at this
    // subsystem. Instruments also has a built-in Points of Interest track that
    // needs no configuration at all, but a signposter only lands in it if its
    // category is the literal string "PointsOfInterest" — a magic value, and one
    // that would read here as though it referred to MapKit's points of interest,
    // which is a completely different thing that this code also deals in. The
    // ambiguity is not worth the one-time convenience.
    static let poiSearch = OSSignposter(subsystem: subsystem, category: "poi-search")
}

// MARK: - A note on privacy, since it is the easy thing to get wrong

// Logger redacts interpolated strings as <private> in release builds unless the
// site says otherwise, and that default is right: it is what stops a log line
// becoming a data leak. But a redacted diagnostic is not a quieter diagnostic,
// it is a useless one — "Could not find file: <private>" tells whoever is
// reading it strictly less than nothing, because it looks like an answer.
//
// So every site in Data Handling was decided individually, and the policy that
// came out of it is worth stating once here rather than re-arguing at each one:
//
// - Song identity — titles, songName, mp3 filenames — is marked .public. These
//   lines exist to name the song that failed, and there is no version of them
//   that works without it. What this exposes is which tracks are in the user's
//   library, on the user's own device log. That is a real disclosure and a small
//   one, and it is the price of the import and playback paths being debuggable
//   at all.
//
// - Anything derived from the user's location is not logged, at any privacy
//   level. Coordinates, POI names, place counts near a specific fix: none of it
//   appears in any line this task wrote. The location and context categories log
//   authorization states, error codes and context *names* — "switched context to
//   Beach" says something about where the user is, but at the resolution of a
//   mood rather than a coordinate, and it is the single most useful line in the
//   app for explaining why the music changed.
//
// - Errors are interpolated through String(describing:) and marked .public. An
//   error whose text is redacted cannot be acted on, and the errors reaching
//   these sites come from AVAudioSession, FileManager and SwiftData rather than
//   from anything the user typed. The exception would be an error carrying a
//   full path to an imported file, which contains a song name — already covered
//   by the first rule above.
//
// String(describing:) rather than bare interpolation of the error, incidentally,
// because OSLogMessage has no interpolation overload for an arbitrary Error
// existential. It also preserves exactly what print produced: the full Swift
// description including any associated values, rather than the frequently empty
// localizedDescription.
