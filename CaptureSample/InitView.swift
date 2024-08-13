//
//  InitView.swift
//  CaptureSample
//
//  Created by ryan on 2024/8/13.
//  Copyright © 2024 Apple. All rights reserved.
//

import Foundation
import SwiftUI

struct InitView: View {
    @ObservedObject var model: CameraViewModel
    @State var showCameraView: Bool = false
    @State var showCaptureFolderView: Bool = false
    var body: some View {
        ZStack{
            Color(red: 0, green: 0, blue: 0.01, opacity: 1.0)
                .edgesIgnoringSafeArea(/*@START_MENU_TOKEN@*/.all/*@END_MENU_TOKEN@*/)
            VStack{
                NavigationLink(destination: ContentView(model: model),
                                isActive: self.$showCameraView) {
                    EmptyView()
                }
                                .frame(width: 0, height: 0)
                                .disabled(true)
                NewCaptureButton(showCameraView: self.$showCameraView)
                Spacer()
                    .frame(height: 50)
                NavigationLink(destination: CaptureFoldersView(model: model, isFromButton: false),
                                isActive: self.$showCaptureFolderView) {
                    EmptyView()
                }
                                .frame(width: 0, height: 0)
                                .disabled(true)
                PreviousCapturesButton(showCaptureFolderView: self.$showCaptureFolderView)
            }
        }
        .navigationBarHidden(true)
    }
}

struct NewCaptureButton: View {
    @Binding var showCameraView: Bool
    var body: some View {
        Button(action: {
            showCameraView = true
        }, label: {
            Text("New Capture")
                .padding(.horizontal, 35.0)
                .padding(.vertical, 10.0)
                .font(.title2)
        })
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }
}

struct PreviousCapturesButton: View {
    @Binding var showCaptureFolderView: Bool
    var body: some View {
        Button(action: {
            showCaptureFolderView = true
        }, label: {
            Text("Previous Captures")
                .padding(.all, 10.0)
                .font(.title2)
                .foregroundColor(.black)
        })
        .buttonStyle(.borderedProminent)
        .tint(Color(uiColor: .lightGray))
    }
}

//#if DEBUG
//struct InitView_Previews: PreviewProvider {
//    @StateObject private static var model = CameraViewModel()
//    static var previews: some View {
//        InitView(model: model)
//    }
//}
//#endif // DEBUG
