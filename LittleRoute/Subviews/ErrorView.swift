import SwiftUI


// Currently only using this as an error screen for location handling
// @TODO: populate other views with this popup and create cases for wifi and music playback errors

struct ErrorView: View {
    // MARK: - Properties
    let errorTitle: String
    let errorMessage: String
    let fixInstructions: String
    var onRetryAction: (() -> Void)?
    
    // MARK: - Init with default values
    init(
        errorTitle: String = "Something went wrong",
        errorMessage: String,
        fixInstructions: String,
        onRetryAction: (() -> Void)? = nil
    ) {
        self.errorTitle = errorTitle
        self.errorMessage = errorMessage
        self.fixInstructions = fixInstructions
        self.onRetryAction = onRetryAction
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundColor(.red)
                .padding(.bottom, 10)
            
            Text(errorTitle)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(errorMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("How to fix:")
                    .font(.headline)
                    .fontWeight(.medium)
                
                Text(fixInstructions)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.1), radius: 5)
            )
            .padding(.horizontal)
            
            if let retry = onRetryAction {
                Button(action: retry) {
                    Text("Try Again")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.top, 20)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

// MARK: - Preview
struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ErrorView(
            errorTitle: "Location Access Required",
            errorMessage: "We couldn't access your location. Location services are needed to use this app.",
            fixInstructions: "Please go to Settings > Privacy > Location Services and enable location for LittleRoute.",
            onRetryAction: { print("Retry tapped") }
        )
    }
}

/*
ErrorView(
    errorTitle: "No Internet Connection",
    errorMessage: "We couldn't connect to our servers. Please check your internet connection.",
    fixInstructions: "Make sure Wi-Fi or cellular data is turned on and try again.",
    onRetryAction: { checkConnection() }
)
*/