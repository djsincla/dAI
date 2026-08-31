import NotebookKit
import SwiftUI

/// What everything on screen means.
///
/// **Written because the window shows a great deal and explains none of it.** A
/// turn carries a retrieval depth, a machine name, a presence state, an elapsed
/// time, two model names and a row of scores, and every one of them is there
/// because it changes how the answer should be read. Somebody who cannot tell
/// which of those is a warning is being shown evidence they cannot use.
///
/// Organised by where a thing appears rather than by what it is, because that is
/// how the question arrives: somebody is looking at a badge and wants to know
/// what it means.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What the window is telling you")
                    .font(Type.question)
                    .foregroundStyle(Palette.ink)
                    .padding(.bottom, 6)
                Text("Every fact recorded with an answer, and why it is there.")
                    .font(.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.bottom, 26)

                section("The line under each answer")
                para("Provenance: what produced this answer and where. Read left "
                   + "to right.")
                item("k 6 · semantic",
                     "Six passages were retrieved and sent to the model. "
                   + "Semantic means the search was pure vector similarity; "
                   + "hybrid would blend keyword matching in as well.")
                item("rotorua",
                     "Which machine in the fleet generated the answer.")
                item("ACTIVE",
                     "That machine's presence: whether somebody was using it. "
                   + "This is the one element that is a warning rather than a "
                   + "fact, and it is coloured accordingly.")
                item("5.4s",
                     "Wall clock from pressing return to the answer arriving. A "
                   + "long first answer is usually a cold model load or a prompt "
                   + "cache miss, not a slow machine.")
                item("cut at 256",
                     "Only present when the answer stopped early. The number is "
                   + "what the fleet allowed, which may be less than was asked "
                   + "for.")
                item("Qwen3-30B-A3B-Instruct",
                     "The model that wrote the answer.")
                item("Qwen3-Embedding-0.6B-8bit",
                     "The model that found the passages, at the far right in the "
                   + "quietest ink. It never changes within a notebook, so it is "
                   + "the least urgent thing there, and the first thing to check "
                   + "if a notebook starts returning nonsense.")

                section("Presence, and why answers stop early")
                para("A fleet machine belongs to whoever is sitting at it. While "
                   + "somebody is, the machine still answers but is limited in "
                   + "how much it may produce. That limit is why an answer can "
                   + "stop mid sentence.")
                policy()
                para("Amber means the machine was in use and the answer may have "
                   + "been cut rather than finished. Teal means nothing was "
                   + "constraining it. If an answer really was cut, an orange "
                   + "notice appears above the prose as well.")
                note("Raising Longest answer in Settings will not lift a policy "
                   + "cap. The answer has to land on a machine nobody is using.")

                section("The scores beside each citation")
                para("Cosine similarity between the question and that passage, "
                   + "from 0 to 1. They are shown because whether the right "
                   + "passage was found is the first question about any answer, "
                   + "and it can only be judged at a glance if the numbers are "
                   + "on screen.")
                para("What matters is the spread rather than the absolute value. "
                   + "0.85 above 0.52 above 0.35 means retrieval found something "
                   + "clearly better than the rest. Six passages all within a few "
                   + "points of each other usually means the corpus does not "
                   + "answer the question, and the model is about to do its best "
                   + "with six weak matches.")
                item("Clicking a citation",
                     "Opens the original at that page. Citation names inside the "
                   + "answer itself are links too, where the model named a "
                   + "passage it was given.")

                section("Sources")
                para("Each source can be switched off. Its chunks stay in the "
                   + "index and are skipped at query time rather than deleted, "
                   + "so turning one back on costs nothing and needs no "
                   + "re-embedding. Which sources were on is recorded with each "
                   + "turn, because two identical questions with different "
                   + "answers are usually explained by this rather than by the "
                   + "model.")

                section("The record")
                para("A notebook is a folder. originals/ holds what was dropped "
                   + "in, byte for byte, and record.jsonl holds one line per "
                   + "exchange. Those two are the work and cannot be recovered "
                   + "if lost. The index and the extracted text are derived from "
                   + "the originals and can be rebuilt in minutes.")
                item("Export",
                     "⌘E writes the whole record as Markdown, including the "
                   + "scores, the machine and whether an answer was cut. Right "
                   + "click a turn to copy just that one.")
                item("History",
                     "Up and down in the question field walk back through what "
                   + "was asked here before, as a shell does.")

                section("Settings")
                item("Gateway and key",
                     "Where the fleet is and the credential to reach it. "
                   + "Retrieval always happens on this machine; only the "
                   + "retrieved passages and the question travel.")
                item("Model",
                     "Which model answers, chosen from what the fleet reports it "
                   + "can serve. Left as Whatever the fleet is serving, the "
                   + "fleet decides per request.")
                item("Longest answer",
                     "A ceiling, not a target. Nothing streams here, so a longer "
                   + "answer is a longer silence rather than a longer scroll, and "
                   + "a model that finishes early costs nothing extra.")
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(Palette.page)
    }

    // ------------------------------------------------------------- pieces

    private func section(_ title: String) -> some View {
        Text(title)
            .font(Type.rowTitle)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Palette.accent)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(Type.answer)
            .lineSpacing(4)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)
    }

    private func item(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Type.score)
                .foregroundStyle(Palette.accent)
            Text(text)
                .font(.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warningSoft, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
    }

    /// The policy table, which is the fleet's and not this app's.
    private func policy() -> some View {
        VStack(spacing: 0) {
            ForEach(Self.states, id: \.0) { state, meaning, cap, caps in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(state)
                        .font(Type.stateBadge)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(caps ? Palette.warningSoft : Palette.accentSoft,
                                    in: Capsule())
                        .foregroundStyle(caps ? Palette.warning : Palette.accent)
                        .frame(width: 76, alignment: .leading)
                    Text(meaning)
                        .font(.callout).foregroundStyle(Palette.inkSecondary)
                    Spacer(minLength: 0)
                    Text(cap)
                        .font(Type.provenance).monospacedDigit()
                        .foregroundStyle(caps ? Palette.warning : Palette.inkSecondary)
                }
                .padding(.vertical, 5)
                Rule()
            }
        }
        .padding(.bottom, 12)
    }

    private static let states: [(String, String, String, Bool)] = [
        ("ACTIVE",  "somebody is typing",           "256 tokens",   true),
        ("PASSIVE", "logged in, not touching it",   "256 tokens",   true),
        ("IDLE",    "idle a while",                 "256 tokens",   true),
        ("LOCKED",  "screen locked",                "2,048 tokens", false),
        ("ABSENT",  "logged out",                   "4,096 tokens", false),
    ]
}
