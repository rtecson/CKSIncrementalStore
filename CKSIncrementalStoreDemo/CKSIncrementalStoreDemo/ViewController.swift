//
//  TasksViewController.swift
//  Pomodoro
//
//  Created by Nofel Mahmood on 18/06/2015.
//  Copyright (c) 2015 Ninish. All rights reserved.
//

import UIKit
import CoreData

class ViewController: UIViewController,UITableViewDataSource,UITableViewDelegate,UITextFieldDelegate {
    
    @IBOutlet var tasksTableView:UITableView!
    @IBOutlet var newTaskTextField:UITextField!
    
    var tasks:Array<Task> = Array<Task>()
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.newTaskTextField.delegate = self
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "syncFinished:", name: CKSIncrementalStoreDidFinishSyncOperationNotification, object: CoreDataStack.sharedStack.cksIncrementalStore)
        
        
        self.loadTasks()
        self.tasksTableView.reloadData()
        
        // Do any additional setup after loading the view.
    }
    
    func textFieldShouldReturn(textField: UITextField) -> Bool {
        
        textField.resignFirstResponder()
        return true
    }
    func textFieldDidEndEditing(textField: UITextField) {
        
        var newTask:Task = NSEntityDescription.insertNewObjectForEntityForName("Task", inManagedObjectContext: CoreDataStack.sharedStack.managedObjectContext!) as! Task
        newTask.name = textField.text
        CoreDataStack.sharedStack.managedObjectContext?.save(nil)
        
        textField.resignFirstResponder()
        self.loadTasks()
        self.tasksTableView.reloadData()
    }
    func loadTasks()
    {
        CoreDataStack.sharedStack.managedObjectContext?.reset()
        var fetchRequest = NSFetchRequest(entityName: "Task")
        var error:NSErrorPointer = nil
        var results = CoreDataStack.sharedStack.managedObjectContext?.executeFetchRequest(fetchRequest, error: error)
        
        if error == nil && results?.count > 0
        {
            self.tasks = Array<Task>()
            for task in results as! [Task]
            {
                CoreDataStack.sharedStack.managedObjectContext?.refreshObject(task, mergeChanges: false)
                self.tasks.append(task)
            }
        }
    }
    func syncFinished(notification:NSNotification)
    {
        self.loadTasks()
        self.tasksTableView.reloadData()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        
        // Dispose of any resources that can be recreated.
    }
    
    func tableView(tableView: UITableView, commitEditingStyle editingStyle: UITableViewCellEditingStyle, forRowAtIndexPath indexPath: NSIndexPath) {
        
        if editingStyle == UITableViewCellEditingStyle.Delete
        {
            CoreDataStack.sharedStack.managedObjectContext?.deleteObject(self.tasks[indexPath.row])
            CoreDataStack.sharedStack.managedObjectContext?.save(nil)
            self.loadTasks()
            tableView.deleteRowsAtIndexPaths([indexPath], withRowAnimation: UITableViewRowAnimation.Left)
        }
    }
    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        
        var alertViewController = UIAlertController(title: "New Task Name", message: "Enter new task name", preferredStyle: UIAlertControllerStyle.Alert)
        alertViewController.addTextFieldWithConfigurationHandler { (textField) -> Void in
            
            textField.placeholder = "Task Name"
            textField.keyboardType = UIKeyboardType.Default
        }
        var doneAction = UIAlertAction(title: "Done", style: UIAlertActionStyle.Default) { (alertAction) -> Void in
            
            println("Done did press")
            var taskName = (alertViewController.textFields?.first as! UITextField).text
            NSOperationQueue.mainQueue().addOperationWithBlock({ () -> Void in
                
                var newTask:Task = self.tasks[indexPath.row]
                newTask.name = taskName
                var error:NSErrorPointer = nil
                CoreDataStack.sharedStack.managedObjectContext?.save(error)
                self.tasksTableView.reloadData()
            })
        }
        alertViewController.addAction(doneAction)
        self.presentViewController(alertViewController, animated: true, completion: nil)
    }
    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        return self.tasks.count
    }
    
    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        
        var cell: UITableViewCell = tableView.dequeueReusableCellWithIdentifier("SimpleTableIdentifier") as! UITableViewCell
        
        cell.textLabel?.text = (self.tasks[indexPath.row] as Task).name
        return cell
    }
    /*
    // MARK: - Navigation
    
    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
    // Get the new view controller using segue.destinationViewController.
    // Pass the selected object to the new view controller.
    }
    */
    
}
