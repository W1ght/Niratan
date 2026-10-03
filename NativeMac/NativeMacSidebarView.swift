import SwiftUI

struct NativeMacSidebarView: View {
    @Binding var selection: NativeMacSection?

    var body: some View {
        VStack(spacing: 0) {
            sidebarBrandHeader

            List(selection: $selection) {
                ForEach(NativeMacSection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .lineLimit(1)

                            Text(section.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.leading, 16, for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
        .background {
            NativeGlassPageBackground()
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: 12) {
            Image("NiratanSidebarIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(.black.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            Text("Niratan")
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
