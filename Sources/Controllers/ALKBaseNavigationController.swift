//
//  ALBaseNavigationController.swift
//  ApplozicSwift
//
//  Created by Mukesh Thawani on 04/05/17.
//  Copyright © 2017 Applozic. All rights reserved.
//

import Foundation
public class ALKBaseNavigationViewController: UINavigationController {
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        
        //Keep the default application status bar
        //setNeedsStatusBarAppearanceUpdate()
    }
    
    override public func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    //Keep the default application status bar
    /*
    override public var preferredStatusBarStyle: UIStatusBarStyle {
        return UIStatusBarStyle.lightContent
    }*/
    
}
