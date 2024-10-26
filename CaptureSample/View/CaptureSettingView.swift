//
//  CaptureSettingView.swift
//  CaptureSample
//
//  Created by lychen on 2024/10/22.
//  Copyright © 2024 Apple. All rights reserved.
//

import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.lychen.CaptureSample", category: "UploadView")


struct CaptureSettingView: View {
    @ObservedObject var model: ARViewModel
    @State private var checkpointsNumString: String = "20"
    @State private var selectedTrackNum: Int = 2
    @FocusState private var isFocused: Bool // to close keyboard
    
    init(model: ARViewModel){
        self.model = model
        
        self._checkpointsNumString = State(initialValue: "\(model.numOfCheckpoints)")
        self._selectedTrackNum = State(initialValue: model.numOfCaptureTrack)
    }
    
    var body: some View {
            ZStack(alignment: .leading) {
                Color(red: 0, green: 0, blue: 0.01, opacity: 1.0)
                    .edgesIgnoringSafeArea(/*@START_MENU_TOKEN@*/.all/*@END_MENU_TOKEN@*/)
                VStack(){
                    HStack{
                        Text("Capture Configuration")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(Color.white)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }

                    HStack{
                        Text("In this page, you can customize your capturing settings")
                            .foregroundColor(Color.gray)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
//                    NumOfCaptureTrackView(model: model)
//                    NumOfCheckpoints(model: model)
                    NumOfCaptureTrackView(selectedTrackNum: $selectedTrackNum)
                    NumOfCheckpoints(checkpointsNumString: $checkpointsNumString, isFocused: $isFocused)
                                    
                    Spacer()
                    Button(action: {
                        if let newValue = Int(checkpointsNumString), newValue > 0 {
//                            model.numOfCheckpoints = newValue
//                            model.numOfCaptureTrack = selectedTrackNum
                            model.updateCaptureSettings(numOfCheckpoints: newValue, numOfCaptureTrack: selectedTrackNum)
                            isFocused = false
                        } else {
                            // Handle invalid input, e.g., show an alert
                            print("Invalid input")
                        }
                    }) {
                        Text("Update")
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    
                    Spacer()
                        .frame(height: 30)
                    
                }
                .padding(.horizontal, 10.0)
            }
            .onAppear() {
                model.pauseARSession()  // In this page, pause session
            }
            .onDisappear {
                model.resumeARSession()
            }
        }
    }

struct NumOfCaptureTrackView: View {
//    @ObservedObject var model: ARViewModel
    @Binding var selectedTrackNum: Int

    var body: some View {
        VStack {
            HStack{
                Text("Number of Capture Tracks")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.white)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.top, 20)
            HStack{
                Text("How many height needs to be captured")
                    .foregroundColor(Color.gray)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
        }
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.lightGray))
                    .frame(height: 50)

                Picker("Number of Tracks", selection: $selectedTrackNum) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .accentColor(.black)
                .pickerStyle(MenuPickerStyle())
                .padding(.horizontal)
                .foregroundColor(.white)
            }
        }
    }
}
struct NumOfCheckpoints: View {
//    @ObservedObject var model: ARViewModel
    @Binding var checkpointsNumString: String
    @FocusState.Binding var isFocused: Bool
    
    
    var body: some View {
        VStack {
            HStack{
                Text("Number of Checkpoints")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.white)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.top, 20)
            HStack{
                Text("How many points in a capture track")
                    .foregroundColor(Color.gray)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            TextField("", text: $checkpointsNumString)
                .padding()
                .frame(height: 50)
                .background(Color(.lightGray))
                .cornerRadius(8)
                .foregroundColor(.black)
                .keyboardType(.numberPad)
                .focused($isFocused)
            //                .onChange(of: isFocused) { focused in
            //                    if focused {
            //                        model.pauseARSession()
            //                    } else {
            //                        model.resumeARSession()
            //                    }
            //                }
            
            //            Spacer()
        }
      
    }
}

//#if DEBUG
//struct CaptureSettingView_Previews: PreviewProvider {
//    static var previews: some View {
//        var datasetWriter = DatasetWriter()
//        let model = ARViewModel(datasetWriter: datasetWriter)
//        CaptureSettingView(model: model)
//    }
//}
//#endif // DEBUG
